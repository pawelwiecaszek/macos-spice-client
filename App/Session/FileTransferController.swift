import AppKit
import Observation
import SpiceKit

/// Copies files into the guest through spice-vdagent (drag & drop or "Send Files…").
/// Files are sent one after another; they land in the guest agent's download folder.
@MainActor
@Observable
final class FileTransferController {
    typealias Sender = @Sendable (URL, @escaping @Sendable (Int64, Int64) -> Void) async throws -> Void
    static let maximumQueuedFiles = 256

    private struct QueuedFile {
        let url: URL
        let hasSecurityScope: Bool
    }
    private struct Progress: Sendable {
        let transfer: UUID
        let fraction: Double
    }

    private(set) var currentName: String?
    private(set) var fraction: Double = 0
    private(set) var queued = 0
    var errorMessage: String?

    @ObservationIgnored private let sender: Sender
    @ObservationIgnored private let startAccess: (URL) -> Bool
    @ObservationIgnored private let isReadable: (URL) -> Bool
    @ObservationIgnored private let stopAccess: (URL) -> Void
    @ObservationIgnored private var queue: [QueuedFile] = []
    @ObservationIgnored private(set) var worker: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var activeTransfer: UUID?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var progressSink: AsyncStream<Progress>.Continuation?

    init(session: SpiceSession, sender: Sender? = nil,
         startAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         isReadable: @escaping (URL) -> Bool = { FileManager.default.isReadableFile(atPath: $0.path) },
         stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.sender = sender ?? { url, progress in try await session.sendFile(url, progress: progress) }
        self.startAccess = startAccess
        self.isReadable = isReadable
        self.stopAccess = stopAccess
    }

    var isBusy: Bool { currentName != nil }

    func chooseAndSend() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose files to copy into the virtual machine")
        guard panel.runModal() == .OK else { return }
        send(panel.urls)
    }

    func send(_ urls: [URL]) {
        for url in urls {
            guard queue.count < Self.maximumQueuedFiles else {
                errorMessage = String(localized: "The file queue is full. Send the remaining files after these transfers finish.")
                break
            }
            let scoped = startAccess(url)
            guard scoped || isReadable(url) else { continue }
            queue.append(QueuedFile(url: url, hasSecurityScope: scoped))
        }
        queued = queue.count
        guard worker == nil, !queue.isEmpty else { return }
        generation &+= 1
        let identity = generation
        let (progress, sink) = AsyncStream<Progress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        progressSink = sink
        progressTask = Task { [weak self] in
            for await update in progress {
                guard !Task.isCancelled, let self, self.generation == identity,
                      self.activeTransfer == update.transfer else { continue }
                self.fraction = update.fraction
            }
        }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.drain(generation: identity, progress: sink)
        }
    }

    func cancel() {
        generation &+= 1
        worker?.cancel()
        worker = nil
        finishProgress()
        for file in queue { release(file) }
        queue.removeAll()
        queued = 0
        currentName = nil
        fraction = 0
        activeTransfer = nil
    }

    private func drain(generation identity: UInt64, progress: AsyncStream<Progress>.Continuation) async {
        defer {
            if generation == identity {
                for file in queue { release(file) }
                queue.removeAll()
                queued = 0
                currentName = nil
                activeTransfer = nil
                worker = nil
                finishProgress()
            }
        }
        while generation == identity, !queue.isEmpty, !Task.isCancelled {
            let file = queue.removeFirst()
            // An active transfer retains only its own scope until the sender exits.
            // Cancel releases queued files independently, even if the sender is late.
            defer { release(file) }
            queued = queue.count
            currentName = file.url.lastPathComponent
            fraction = 0
            let transfer = UUID()
            activeTransfer = transfer
            do {
                try await sender(file.url) { sent, total in
                    let value = total > 0 ? min(1, max(0, Double(sent) / Double(total))) : 1
                    progress.yield(Progress(transfer: transfer, fraction: value))
                }
                guard generation == identity, !Task.isCancelled else { return }
            } catch is CancellationError {
                return
            } catch {
                guard generation == identity, !Task.isCancelled else { return }
                let reason = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
                errorMessage = String(localized: "“\(file.url.lastPathComponent)” wasn’t copied: \(reason)")
            }
        }
    }

    private func release(_ file: QueuedFile) {
        if file.hasSecurityScope { stopAccess(file.url) }
    }

    private func finishProgress() {
        progressSink?.finish()
        progressSink = nil
        progressTask?.cancel()
        progressTask = nil
    }
}
