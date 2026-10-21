import Testing
@testable import USBEmulation
import USBRedirWire

/// A YubiKey-like card: T=1 ATR, answers SELECT with 90 00.
actor FakeCCIDCard: CCIDCard {
    nonisolated let displayName = "Fake Key"
    private(set) var connects = 0
    private(set) var disconnects = 0
    static let atr: [UInt8] = [0x3B, 0xFD, 0x13, 0x00, 0x00, 0x81, 0x31, 0xFE, 0x15, 0x80, 0x73, 0xC0, 0x21, 0xC0, 0x57,
                               0x59, 0x75, 0x62, 0x69, 0x4B, 0x65, 0x79, 0x40]

    func connect() async throws -> [UInt8] {
        connects += 1
        return Self.atr
    }

    func transmit(_ apdu: [UInt8]) async throws -> [UInt8] {
        try await Task.sleep(for: .milliseconds(20))  // a slow card: IN must wait for it
        return [UInt8](repeating: 0x42, count: 200) + [0x90, 0x00]
    }

    func disconnect() async { disconnects += 1 }
}

private func command(_ type: UInt8, seq: UInt8, data: [UInt8] = [], specific: [UInt8] = [0, 0, 0]) -> [UInt8] {
    let n = UInt32(data.count)
    return [type, UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24), 0, seq] + specific + data
}

/// Reads one complete RDR_to_PC message in 64-byte packets, like a host controller.
private func readResponse(_ reader: EmulatedCCIDReader) async -> [UInt8] {
    var bytes = await reader.bulk(endpoint: 0x81, data: [], length: 64).data
    guard bytes.count >= 10 else { return bytes }
    let total = 10 + (Int(bytes[1]) | Int(bytes[2]) << 8)
    while bytes.count < total {
        bytes += await reader.bulk(endpoint: 0x81, data: [], length: 64).data
    }
    return bytes
}

@Suite("Emulated CCID reader")
struct CCIDReaderTests {
    @Test func descriptorsAreWellFormed() {
        #expect(CCIDDescriptors.device.count == 18)
        #expect(CCIDDescriptors.ccidClass.count == 54)
        let config = CCIDDescriptors.configuration
        #expect(config.count == 9 + 9 + 54 + 21)
        #expect(Int(config[2]) | Int(config[3]) << 8 == config.count)
        // Walk the descriptor chain: lengths must tile the buffer exactly.
        var offset = 0
        var types: [UInt8] = []
        while offset < config.count {
            #expect(config[offset] > 0)
            types.append(config[offset + 1])
            offset += Int(config[offset])
        }
        #expect(offset == config.count)
        #expect(types == [0x02, 0x04, 0x21, 0x05, 0x05, 0x05])
        #expect(config[9 + 5] == 0x0B)  // interface class: smart card
    }

    @Test func powerOnTransferAndSlotStatus() async {
        let card = FakeCCIDCard()
        let reader = EmulatedCCIDReader(card: card)

        // Slot status before power-on: card present, inactive.
        _ = await reader.bulk(endpoint: 0x02, data: command(0x65, seq: 1), length: 0)
        let status = await readResponse(reader)
        #expect(status[0] == 0x81 && status[6] == 1 && status[7] == 0x01)

        _ = await reader.bulk(endpoint: 0x02, data: command(0x62, seq: 2), length: 0)
        let powerOn = await readResponse(reader)
        #expect(powerOn[0] == 0x80 && powerOn[6] == 2 && powerOn[7] == 0x00)
        #expect(Array(powerOn.dropFirst(10)) == FakeCCIDCard.atr)

        // T=1 parameters derived from the ATR.
        _ = await reader.bulk(endpoint: 0x02, data: command(0x6C, seq: 3), length: 0)
        let params = await readResponse(reader)
        #expect(params[0] == 0x82 && params[9] == 1 && params.count == 17)

        // A response longer than one packet arrives over several IN transfers; the IN that
        // starts before the slow card answered simply waits.
        async let response = readResponse(reader)
        _ = await reader.bulk(endpoint: 0x02, data: command(0x6F, seq: 4, data: [0x00, 0xA4, 0x04, 0x00, 0x05, 1, 2, 3, 4, 5]), length: 0)
        let block = await response
        #expect(block[0] == 0x80 && block[6] == 4)
        #expect(block.count == 10 + 202)
        #expect(Array(block.suffix(2)) == [0x90, 0x00])

        await reader.close()
        #expect(await card.connects == 1)
        #expect(await card.disconnects == 1)
    }

    @Test func rejectsOversizedAndUnsupportedCommands() async {
        let reader = EmulatedCCIDReader(card: FakeCCIDCard())
        var huge = command(0x6F, seq: 9)
        huge[2] = 0x10  // dwLength = 4096 > 261
        _ = await reader.bulk(endpoint: 0x02, data: huge, length: 0)
        let oversized = await readResponse(reader)
        #expect(oversized[0] == 0x81 && oversized[7] & 0x40 != 0)

        _ = await reader.bulk(endpoint: 0x02, data: command(0x6B, seq: 10), length: 0)  // Escape
        let escape = await readResponse(reader)
        #expect(escape[7] & 0x40 != 0 && escape[8] == 0)  // failed, CMD_NOT_SUPPORTED
        await reader.close()
    }

    @Test func interruptNotifiesOnceThenWaitsUntilAborted() async {
        let reader = EmulatedCCIDReader(card: FakeCCIDCard())
        let first = await reader.interrupt(endpoint: 0x83, data: [], length: 8)
        #expect(first.status == .success && first.data == [0x50, 0x03])
        let pending = Task { await reader.interrupt(endpoint: 0x83, data: [], length: 8) }
        try? await Task.sleep(for: .milliseconds(50))
        await reader.abort(endpoint: 0x83)
        #expect(await pending.value.status == .cancelled)
        await reader.close()
    }

    /// Re-audit 3: commands without reads are refused once answers pile up.
    @Test func unreadResponsesAreBounded() async {
        let reader = EmulatedCCIDReader(card: FakeCCIDCard())
        var stalled = false
        for seq in 0..<200 {
            let result = await reader.bulk(endpoint: 0x02, data: command(0x65, seq: UInt8(seq)), length: 0)
            if result.status == .stall { stalled = true; break }
        }
        #expect(stalled)
        // One huge OUT transfer full of commands is cut off as well.
        let batch = (0..<500).flatMap { command(0x65, seq: UInt8($0 & 0xFF)) }
        #expect(await reader.bulk(endpoint: 0x02, data: batch, length: 0).status == .stall)
        await reader.close()
    }

    /// Re-audit 4: a second interrupt wait ends the first instead of leaking it.
    @Test func newerInterruptWaitEndsTheOlderOne() async {
        let reader = EmulatedCCIDReader(card: FakeCCIDCard())
        _ = await reader.interrupt(endpoint: 0x83, data: [], length: 8)  // initial notification
        let older = Task { await reader.interrupt(endpoint: 0x83, data: [], length: 8) }
        try? await Task.sleep(for: .milliseconds(30))
        let newer = Task { await reader.interrupt(endpoint: 0x83, data: [], length: 8) }
        #expect(await older.value.status == .cancelled)
        newer.cancel()
        #expect(await newer.value.status == .cancelled)
        await reader.close()
    }

    @Test func atrProtocols() {
        #expect(ATR.protocols(FakeCCIDCard.atr).contains(1))
        #expect(ATR.protocols([0x3B, 0x00]) == [0])
    }
}
