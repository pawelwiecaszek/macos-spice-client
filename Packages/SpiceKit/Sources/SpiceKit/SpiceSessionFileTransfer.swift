import Foundation

/// Mutable transfer state is accessed only on its owning SpiceSession actor.
final class SessionFileTransferState {
    struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<FileTransferResult, any Error>
    }
    let timeout: Duration
    var nextID: UInt32 = 1
    var waiters: [UInt32: Waiter] = [:]
    var active: Set<UInt32> = []
    var ready: Set<UInt32> = []
    var terminal: Set<UInt32> = []
    var early: [UInt32: [FileTransferResult]] = [:]
    init(timeout: Duration) { self.timeout = max(.milliseconds(1), min(timeout, .seconds(120))) }
}

extension SpiceSession {
    // MARK: File transfer (drag & drop to the guest)

    public enum FileTransferError: Error, Equatable, Sendable, LocalizedError {
        case agentUnavailable
        case disabledByGuest
        case rejected(FileTransferResult)
        case notAFile
        case unreadable
        case transferLimit
        case statusTimedOut

        public var errorDescription: String? {
            switch self {
            case .agentUnavailable: "The SPICE guest agent (spice-vdagent) isn’t running in the virtual machine."
            case .disabledByGuest: "File transfer is disabled in the virtual machine."
            case .rejected(.notEnoughSpace): "There isn’t enough free space in the virtual machine."
            case .rejected(.sessionLocked): "The virtual machine’s session is locked."
            case .rejected(.cancelled): "The transfer was cancelled."
            case .rejected(.disabled): "File transfer is disabled in the virtual machine."
            case .rejected: "The virtual machine couldn’t save the file."
            case .notAFile: "Only files can be sent, not folders."
            case .unreadable: "The file couldn’t be read."
            case .transferLimit: "Too many file transfers are active. Wait for them to finish or reconnect."
            case .statusTimedOut: "The guest did not answer the file transfer. Check its downloads before trying again."
            }
        }
    }

    /// Copies a file to the guest. Status waits are cancellable and bounded; a
    /// timeout is ambiguous and never automatically retries the START request.
    public func sendFile(_ url: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try Task.checkCancellation()
        guard let main, let authorization = await main.fileTransferAuthorization, state == .connected else { throw FileTransferError.agentUnavailable }
        guard !guestAgentCaps.contains(AgentCapability.fileXferDisabled.rawValue) else { throw FileTransferError.disabledByGuest }
        guard fileTransfers.active.count < 16, fileTransfers.nextID != 0 else { throw FileTransferError.transferLimit }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw FileTransferError.notAFile }
        let size = Int64(values?.fileSize ?? 0)
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw FileTransferError.unreadable }
        defer { try? handle.close() }
        let id = fileTransfers.nextID
        fileTransfers.nextID &+= 1
        fileTransfers.active.insert(id)
        defer {
            fileTransfers.active.remove(id)
            fileTransfers.ready.remove(id)
            fileTransfers.terminal.remove(id)
            fileTransfers.early.removeValue(forKey: id)
            fileTransfers.waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
        }
        do {
            try Task.checkCancellation()
            try await main.enqueueFileTransfer(FileTransferCodec.start(id: id, name: url.lastPathComponent, size: UInt64(size)), authorization: authorization)
            let first = try await waitForFileStatus(id)
            guard first == .canSendData else { throw FileTransferError.rejected(first) }
            var sent: Int64 = 0
            while sent < size {
                try Task.checkCancellation()
                if let early = fileTransfers.early[id]?.first, early != .success { throw FileTransferError.rejected(early) }
                while await main.pendingAgentBytes > 1024 * 1024 {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard let chunk = try handle.read(upToCount: min(FileTransferCodec.chunkSize, Int(size - sent))), !chunk.isEmpty else {
                    throw FileTransferError.unreadable
                }
                try await main.enqueueFileTransfer(FileTransferCodec.data(id: id, bytes: Array(chunk)[...]), authorization: authorization)
                try Task.checkCancellation()
                sent += Int64(chunk.count)
                progress(sent, size)
            }
            let result = try await waitForFileStatus(id)
            guard result == .success else { throw FileTransferError.rejected(result) }
            try Task.checkCancellation()
        } catch {
            // Release the file before best-effort protocol cleanup can suspend.
            try? handle.close()
            try? await main.cancelFileTransfer(id: id, authorization: authorization)
            if let admission = error as? AgentFileTransferAdmissionError {
                switch admission {
                case .unavailable: throw FileTransferError.agentUnavailable
                case .disabledByGuest: throw FileTransferError.disabledByGuest
                case .queueFull: throw FileTransferError.transferLimit
                case .invalidMessage: throw FileTransferError.unreadable
                }
            }
            throw error
        }
    }

    private func waitForFileStatus(_ id: UInt32) async throws -> FileTransferResult {
        let token = UUID()
        let timeout = fileTransfers.timeout
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.finishFileWait(id, token: token, error: FileTransferError.statusTimedOut)
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if var early = fileTransfers.early[id], !early.isEmpty {
                let first = early.removeFirst()
                fileTransfers.early[id] = early.isEmpty ? nil : early
                return first
            }
            return try await withCheckedThrowingContinuation { continuation in
                fileTransfers.waiters[id] = SessionFileTransferState.Waiter(token: token, continuation: continuation)
            }
        } onCancel: {
            Task { await self.finishFileWait(id, token: token, error: CancellationError()) }
        }
    }

    private func finishFileWait(_ id: UInt32, token: UUID, error: any Error) {
        guard fileTransfers.waiters[id]?.token == token else { return }
        fileTransfers.waiters.removeValue(forKey: id)?.continuation.resume(throwing: error)
    }

    func fileTransferStatus(id: UInt32, result: FileTransferResult) {
        guard fileTransfers.active.contains(id), !fileTransfers.terminal.contains(id) else { return }
        if result == .canSendData {
            guard fileTransfers.ready.insert(id).inserted else { return }
        } else { fileTransfers.terminal.insert(id) }
        if let waiter = fileTransfers.waiters.removeValue(forKey: id) {
            waiter.continuation.resume(returning: result)
        } else {
            // At most one initial ready and one terminal status per active ID.
            fileTransfers.early[id, default: []].append(result)
        }
    }

    func failFileTransfers(_ result: FileTransferResult) {
        let waiters = fileTransfers.waiters
        fileTransfers.waiters.removeAll()
        for id in fileTransfers.active { fileTransfers.early[id] = [result]; fileTransfers.terminal.insert(id) }
        for waiter in waiters.values { waiter.continuation.resume(returning: result) }
    }

}
