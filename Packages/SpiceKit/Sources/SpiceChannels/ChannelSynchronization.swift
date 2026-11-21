import Foundation
import SpiceWire

/// Session-local ordering barriers. Serials advance only after a channel has processed a message.
public actor ChannelSynchronization {
    public struct Key: Hashable, Sendable {
        public let rawType: UInt8
        public let id: UInt8

        public init(type: ChannelType, id: UInt8) {
            self.init(rawType: type.rawValue, id: id)
        }

        public init(rawType: UInt8, id: UInt8) {
            self.rawType = rawType
            self.id = id
        }
    }

    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case sessionClosed
        case channelClosed
        case unknownChannel
        case duplicateChannel
        case manifestAlreadySealed
        case tooManyChannels
        case tooManyWaiters
        case tooManyDependencies
        case selfDependency
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .sessionClosed: "The SPICE session closed while synchronizing channels."
            case .channelClosed: "A required SPICE channel closed before synchronization completed."
            case .unknownChannel: "The server requested synchronization with an unavailable channel."
            case .duplicateChannel: "A SPICE channel identity was reused before starting a new session."
            case .manifestAlreadySealed: "The SPICE channel list was already established."
            case .tooManyChannels, .tooManyWaiters, .tooManyDependencies: "The server exceeded a channel synchronization limit."
            case .selfDependency: "The server requested an impossible channel synchronization."
            case .timedOut: "SPICE channel synchronization timed out."
            }
        }
    }

    private struct Channel {
        var token: UUID?
        var completed: UInt64 = 0
        var closed = false
    }

    private struct Waiter {
        let owner: Key
        let dependencies: [WaitForChannels.Entry]
        let continuation: CheckedContinuation<Void, any Error>
        let timeout: Task<Void, Never>
    }

    private let waitTimeout: Duration
    private var channels: [Key: Channel] = [:]
    private var expected: Set<Key>?
    private var waiters: [UUID: Waiter] = [:]
    private var stopped = false

    var pendingWaitCount: Int { waiters.count }

    public init(waitTimeout: Duration = .seconds(30)) {
        self.waitTimeout = waitTimeout
    }

    /// Seal the server's channel manifest, retaining channels registered before MAIN_INIT.
    public func expect(_ keys: [Key]) throws {
        guard !stopped else { throw Failure.sessionClosed }
        guard expected == nil else { throw Failure.manifestAlreadySealed }
        let manifest = Set(keys).union(channels.keys)
        guard manifest.count <= 64 else { throw Failure.tooManyChannels }
        expected = manifest
        resolveWaiters()
    }

    public func register(_ key: Key, token: UUID) throws {
        guard !stopped else { throw Failure.sessionClosed }
        if let expected, !expected.contains(key) { throw Failure.unknownChannel }
        if let existing = channels[key] {
            // Display IDs also name server-owned cache/dictionary state. A fresh main
            // session is required before reusing them; do not assume a socket close
            // has already destroyed the server's old objects.
            guard existing.closed && key.rawType != ChannelType.display.rawValue else { throw Failure.duplicateChannel }
        }
        guard channels[key] != nil || channels.count < 64 else { throw Failure.tooManyChannels }
        channels[key] = Channel(token: token)
    }

    public func complete(_ key: Key, token: UUID, serial: UInt64) {
        guard !stopped, var channel = channels[key], !channel.closed, channel.token == token else { return }
        channel.completed = max(channel.completed, serial)
        channels[key] = channel
        resolveWaiters()
    }

    public func wait(
        _ dependencies: [WaitForChannels.Entry], owner: Key, token: UUID, currentSerial: UInt64
    ) async throws {
        try Task.checkCancellation()
        guard !stopped else { throw Failure.sessionClosed }
        guard let channel = channels[owner], !channel.closed, channel.token == token else {
            throw Failure.channelClosed
        }
        guard dependencies.count <= 255 else { throw Failure.tooManyDependencies }
        for entry in dependencies {
            if Key(rawType: entry.channelType, id: entry.channelID) == owner {
                guard entry.messageSerial == 0 ||
                    (entry.messageSerial < currentSerial && entry.messageSerial <= channel.completed) else {
                    throw Failure.selfDependency
                }
            }
        }
        if try satisfied(dependencies) { return }
        guard waiters.count < 64 else { throw Failure.tooManyWaiters }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Cancellation may have arrived before the continuation was installed.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeout = Task { [weak self, waitTimeout] in
                    do { try await Task.sleep(for: waitTimeout) }
                    catch { return }
                    await self?.finish(id, failure: Failure.timedOut)
                }
                waiters[id] = Waiter(
                    owner: owner, dependencies: dependencies, continuation: continuation, timeout: timeout
                )
            }
        } onCancel: {
            Task { await self.finish(id, failure: CancellationError()) }
        }
    }

    /// A manifest entry whose channel could not be opened can never satisfy a barrier.
    public func unavailable(_ key: Key) {
        guard !stopped else { return }
        if channels[key] == nil {
            guard channels.count < 64 else { return }
            channels[key] = Channel(token: nil, closed: true)
        } else {
            channels[key]?.closed = true
        }
        failWaiters(involving: key)
    }

    public func close(_ key: Key, token: UUID) {
        guard let channel = channels[key], channel.token == token, !channel.closed else { return }
        channels[key]?.closed = true
        failWaiters(involving: key)
    }

    public func shutdown() {
        stopped = true
        for id in Array(waiters.keys) { finish(id, failure: Failure.sessionClosed) }
        channels.removeAll()
    }

    private func satisfied(_ dependencies: [WaitForChannels.Entry]) throws -> Bool {
        var ready = true
        for entry in dependencies {
            let key = Key(rawType: entry.channelType, id: entry.channelID)
            if let expected, !expected.contains(key) { throw Failure.unknownChannel }
            if let channel = channels[key] {
                guard !channel.closed else { throw Failure.channelClosed }
                if channel.completed < entry.messageSerial { ready = false }
            } else {
                // Serial zero is the state before the first message, including a pending open.
                if entry.messageSerial > 0 { ready = false }
            }
        }
        return ready
    }

    private func resolveWaiters() {
        for (id, waiter) in waiters {
            do {
                if try satisfied(waiter.dependencies) { finish(id) }
            } catch {
                finish(id, failure: error)
            }
        }
    }

    private func failWaiters(involving key: Key) {
        for (id, waiter) in waiters {
            if waiter.owner == key || waiter.dependencies.contains(where: {
                $0.channelType == key.rawType && $0.channelID == key.id
            }) {
                finish(id, failure: Failure.channelClosed)
            }
        }
    }

    private func finish(_ id: UUID, failure: (any Error)? = nil) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        if let failure { waiter.continuation.resume(throwing: failure) }
        else { waiter.continuation.resume() }
    }
}
