import Foundation
import Testing
@testable import SpiceChannels
import SpiceWire

@Suite("Channel synchronization", .timeLimit(.minutes(1)))
struct ChannelSynchronizationTests {
    private typealias Sync = ChannelSynchronization
    private let owner = Sync.Key(type: .display, id: 0)
    private let peer = Sync.Key(type: .cursor, id: 0)

    private func dependency(_ key: Sync.Key, _ serial: UInt64) throws -> WaitForChannels.Entry {
        var bytes = ByteWriter()
        bytes.writeU8(1)
        bytes.writeU8(key.rawType)
        bytes.writeU8(key.id)
        bytes.writeU64(serial)
        return try #require(WaitForChannels(decoding: bytes.bytes).entries.first)
    }

    private func awaitWaiters(_ count: Int, in sync: Sync) async {
        for _ in 0..<10_000 {
            if await sync.pendingWaitCount == count { return }
            await Task.yield()
        }
        Issue.record("Synchronization did not reach expected waiter count")
    }

    @Test func waitsForProcessedSerialAndFutureRegistration() async throws {
        let sync = Sync()
        let token = UUID(), peerToken = UUID()
        try await sync.register(owner, token: token)
        let entry = try dependency(peer, 2)
        let wait = Task { try await sync.wait([entry], owner: owner, token: token, currentSerial: 1) }
        await awaitWaiters(1, in: sync)
        try await sync.expect([owner, peer])
        try await sync.register(peer, token: peerToken)
        await sync.complete(peer, token: peerToken, serial: 1)
        #expect(await sync.pendingWaitCount == 1)
        await sync.complete(peer, token: peerToken, serial: 2)
        try await wait.value
        #expect(await sync.pendingWaitCount == 0)
    }

    @Test func expectedPeerCanOpenAfterManifest() async throws {
        let sync = Sync()
        let token = UUID(), peerToken = UUID()
        try await sync.register(owner, token: token)
        try await sync.expect([peer])
        let entry = try dependency(peer, 1)
        let wait = Task { try await sync.wait([entry], owner: owner, token: token, currentSerial: 1) }
        await awaitWaiters(1, in: sync)
        try await sync.register(peer, token: peerToken)
        await sync.complete(peer, token: peerToken, serial: 1)
        try await wait.value
    }

    @Test func unplannedPeerFailsWhenManifestSeals() async throws {
        let sync = Sync()
        let token = UUID()
        try await sync.register(owner, token: token)
        let entry = try dependency(peer, 1)
        let wait = Task { try await sync.wait([entry], owner: owner, token: token, currentSerial: 1) }
        await awaitWaiters(1, in: sync)
        try await sync.expect([owner])
        await #expect(throws: Sync.Failure.unknownChannel) { try await wait.value }
        await #expect(throws: Sync.Failure.unknownChannel) {
            try await sync.register(peer, token: UUID())
        }
        await #expect(throws: Sync.Failure.unknownChannel) {
            try await sync.wait([entry], owner: owner, token: token, currentSerial: 1)
        }
    }

    @Test(arguments: [0, 1, 2, 3]) func closureReleasesWaiters(reason: Int) async throws {
        let sync = Sync()
        let token = UUID(), peerToken = UUID()
        try await sync.register(owner, token: token)
        try await sync.register(peer, token: peerToken)
        let entry = try dependency(peer, 1)
        let wait = Task { try await sync.wait([entry], owner: owner, token: token, currentSerial: 1) }
        await awaitWaiters(1, in: sync)
        switch reason {
        case 0: await sync.close(peer, token: peerToken)
        case 1: await sync.unavailable(peer)
        case 2: await sync.close(owner, token: token)
        default: await sync.shutdown()
        }
        await #expect(throws: reason == 3 ? Sync.Failure.sessionClosed : Sync.Failure.channelClosed) {
            try await wait.value
        }
        #expect(await sync.pendingWaitCount == 0)
    }

    @Test func cancellationAndTimeoutRemoveWaiters() async throws {
        let sync = Sync(waitTimeout: .milliseconds(100))
        let token = UUID()
        try await sync.register(owner, token: token)
        let entry = try dependency(peer, 1)
        let wait = Task { try await sync.wait([entry], owner: owner, token: token, currentSerial: 1) }
        await awaitWaiters(1, in: sync)
        wait.cancel()
        await #expect(throws: CancellationError.self) { try await wait.value }
        #expect(await sync.pendingWaitCount == 0)
        await #expect(throws: Sync.Failure.timedOut) {
            try await sync.wait([entry], owner: owner, token: token, currentSerial: 1)
        }
        #expect(await sync.pendingWaitCount == 0)
    }

    @Test func selfDependenciesOnlyAllowCompletedPast() async throws {
        let sync = Sync()
        let token = UUID()
        try await sync.register(owner, token: token)
        try await sync.wait([dependency(owner, 0)], owner: owner, token: token, currentSerial: 1)
        await #expect(throws: Sync.Failure.selfDependency) {
            try await sync.wait([dependency(owner, 1)], owner: owner, token: token, currentSerial: 2)
        }
        await sync.complete(owner, token: token, serial: 1)
        try await sync.wait([dependency(owner, 1)], owner: owner, token: token, currentSerial: 2)
        for serial: UInt64 in [2, 3] {
            await #expect(throws: Sync.Failure.selfDependency) {
                try await sync.wait([dependency(owner, serial)], owner: owner, token: token, currentSerial: 2)
            }
        }
    }

    @Test func staleTokensAndOtherSessionsCannotAdvanceReplacement() async throws {
        let sync = Sync(), other = Sync()
        let token = UUID(), old = UUID(), replacement = UUID()
        try await sync.register(owner, token: token)
        try await sync.register(peer, token: old)
        await sync.close(peer, token: old)
        try await sync.register(peer, token: replacement)
        try await other.register(peer, token: replacement)
        let entry = try dependency(peer, 2)
        let wait = Task { try await sync.wait([entry], owner: owner, token: token, currentSerial: 1) }
        await awaitWaiters(1, in: sync)
        await sync.complete(peer, token: old, serial: 100)
        await sync.close(peer, token: old)
        await other.complete(peer, token: replacement, serial: 100)
        #expect(await sync.pendingWaitCount == 1)
        await sync.complete(peer, token: replacement, serial: 2)
        await sync.complete(peer, token: replacement, serial: 1)
        try await wait.value
        try await sync.wait([entry], owner: owner, token: token, currentSerial: 2)
    }

    @Test func enforcesChannelWaiterAndDependencyBounds() async throws {
        let sync = Sync()
        let token = UUID()
        try await sync.register(owner, token: token)
        await #expect(throws: Sync.Failure.duplicateChannel) {
            try await sync.register(owner, token: UUID())
        }
        let entry = try dependency(peer, 1)
        await #expect(throws: Sync.Failure.tooManyDependencies) {
            try await sync.wait(Array(repeating: entry, count: 256), owner: owner, token: token, currentSerial: 1)
        }
        var tasks: [Task<Void, any Error>] = []
        for _ in 0..<64 {
            tasks.append(Task { try await sync.wait([entry], owner: owner, token: token, currentSerial: 1) })
        }
        await awaitWaiters(64, in: sync)
        await #expect(throws: Sync.Failure.tooManyWaiters) {
            try await sync.wait([entry], owner: owner, token: token, currentSerial: 1)
        }
        await sync.shutdown()
        for task in tasks { _ = await task.result }
        let bounded = Sync()
        for id: UInt8 in 0..<64 { try await bounded.register(.init(rawType: 200, id: id), token: UUID()) }
        await #expect(throws: Sync.Failure.tooManyChannels) {
            try await bounded.register(.init(rawType: 200, id: 64), token: UUID())
        }
    }
    @Test func displayCacheIdentityCannotBeReusedWithinTheSameMainSession() async throws {
        let sync = Sync()
        let token = UUID()
        try await sync.register(owner, token: token)
        await sync.close(owner, token: token)
        await #expect(throws: Sync.Failure.duplicateChannel) { try await sync.register(owner, token: UUID()) }
        let replacementSession = Sync()
        try await replacementSession.register(owner, token: UUID())
        await sync.complete(owner, token: token, serial: 1)
        await replacementSession.shutdown()
    }

}
