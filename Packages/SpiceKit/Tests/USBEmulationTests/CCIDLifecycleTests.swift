import Testing
@testable import USBEmulation

private actor HeldCCIDCard: CCIDCard {
    nonisolated let displayName = "Simulated key"
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var disconnects = 0
    func connect() async throws -> [UInt8] {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return [0x3B, 0]
    }
    func finishConnect() { continuation?.resume(); continuation = nil }
    func transmit(_ apdu: [UInt8]) async throws -> [UInt8] { [0x90, 0] }
    func disconnect() async { disconnects += 1 }
}

@Suite("CCID pending acquisition", .timeLimit(.minutes(1)))
struct CCIDLifecycleTests {
    @Test func closeRevokesPendingPowerOnAndReturnsLateCard() async {
        let card = HeldCCIDCard()
        let reader = EmulatedCCIDReader(card: card)
        let power = Task {
            await reader.bulk(endpoint: 0x02, data: [0x62, 0, 0, 0, 0, 0, 1, 0, 0, 0], length: 0)
        }
        while !(await card.started) { await Task.yield() }
        // Closing must finish even while hardware acquisition remains suspended.
        await reader.close()
        #expect(await card.disconnects == 0)
        await card.finishConnect()
        #expect(await power.value.status == .cancelled)
        #expect(await card.disconnects == 1)
        #expect(await reader.bulk(endpoint: 0x81, data: [], length: 64).status == .cancelled)
        #expect(await reader.setConfiguration(1) == .cancelled)
        #expect(await reader.reset() == false)
        await reader.close()
        #expect(await card.disconnects == 1)
    }

    @Test func resetRevokesPendingPowerOnWithoutPublishingAnOldResponse() async {
        let card = HeldCCIDCard()
        let reader = EmulatedCCIDReader(card: card)
        let power = Task {
            await reader.bulk(endpoint: 0x02, data: [0x62, 0, 0, 0, 0, 0, 1, 0, 0, 0], length: 0)
        }
        while !(await card.started) { await Task.yield() }
        #expect(await reader.reset())
        await card.finishConnect()
        _ = await power.value
        #expect(await card.disconnects == 1)
        // A fresh slot-status command must be the first response after reset.
        _ = await reader.bulk(endpoint: 0x02, data: [0x65, 0, 0, 0, 0, 0, 2, 0, 0, 0], length: 0)
        let status = await reader.bulk(endpoint: 0x81, data: [], length: 64)
        #expect(status.data.count == 10)
        #expect(status.data[0] == 0x81 && status.data[6] == 2)
        #expect(status.data[7] & 3 == 1)
        await reader.close()
    }
}
