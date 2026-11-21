import Testing
import Synchronization
@testable import SmartcardHost

private actor HeldCardSession: MacSmartcardSession {
    nonisolated let atr: [UInt8] = [0x3B, 0]
    nonisolated let isValid = true
    let holdBegin: Bool
    let holdTransmit: Bool
    let holdEnd: Bool
    private var beginWaiter: CheckedContinuation<Void, Never>?
    private var transmitWaiter: CheckedContinuation<Void, Never>?
    private var endWaiter: CheckedContinuation<Void, Never>?
    private(set) var began = false
    private(set) var transmitted = false
    private(set) var ends = 0

    init(holdBegin: Bool = false, holdTransmit: Bool = false, holdEnd: Bool = false) {
        self.holdBegin = holdBegin
        self.holdTransmit = holdTransmit
        self.holdEnd = holdEnd
    }
    func begin() async throws {
        began = true
        if holdBegin { await withCheckedContinuation { beginWaiter = $0 } }
    }
    func transmit(_ apdu: [UInt8]) async throws -> [UInt8] {
        transmitted = true
        if holdTransmit { await withCheckedContinuation { transmitWaiter = $0 } }
        return [0x90, 0]
    }
    func end() async {
        ends += 1
        if holdEnd { await withCheckedContinuation { endWaiter = $0 } }
    }
    func finishEnd() { endWaiter?.resume(); endWaiter = nil }
    func finishBegin() { beginWaiter?.resume(); beginWaiter = nil }
    func finishTransmit() { transmitWaiter?.resume(); transmitWaiter = nil }
}

@Suite("Mac card ownership without hardware", .timeLimit(.minutes(1)))
struct MacSmartcardLifecycleTests {
    @Test func concurrentDisconnectJoinsExclusiveSessionRelease() async throws {
        let session = HeldCardSession(holdEnd: true)
        let card = MacSmartcard(readerName: "Simulated", makeSession: { _ in session })
        _ = try await card.connect()
        let first = Task { await card.disconnect() }
        while await session.ends == 0 { await Task.yield() }
        let finished = Mutex(false)
        let second = Task { await card.disconnect(); finished.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!finished.withLock { $0 })
        await #expect(throws: MacSmartcardError.self) { try await card.connect() }
        await session.finishEnd()
        await first.value
        await second.value
        let ends = await session.ends
        #expect(finished.withLock { $0 } && ends == 1)
    }

    @Test func pendingAcquisitionCannotSurviveDisconnectOrOverlapAnotherConnect() async throws {
        let session = HeldCardSession(holdBegin: true)
        let card = MacSmartcard(readerName: "Simulated", makeSession: { _ in session })
        let connect = Task { try await card.connect() }
        while !(await session.began) { await Task.yield() }
        await #expect(throws: MacSmartcardError.self) { try await card.connect() }
        await card.disconnect()
        #expect(await session.ends == 0)
        await session.finishBegin()
        await #expect(throws: CancellationError.self) { try await connect.value }
        #expect(await session.ends == 1)
        #expect(await card.isPresent == false)
        await card.disconnect()
        #expect(await session.ends == 1)
    }

    @Test func disconnectedCardCannotDeliverAnOldAPDUReply() async throws {
        let session = HeldCardSession(holdTransmit: true)
        let card = MacSmartcard(readerName: "Simulated", makeSession: { _ in session })
        #expect(try await card.connect() == [0x3B, 0])
        let transmit = Task { try await card.transmit([0, 0xA4]) }
        while !(await session.transmitted) { await Task.yield() }
        await card.disconnect()
        await session.finishTransmit()
        await #expect(throws: CancellationError.self) { try await transmit.value }
        #expect(await session.ends == 1)
        #expect(await card.isPresent == false)
    }
}
