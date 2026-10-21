import Testing
@testable import USBEmulation
import USBRedirWire

/// Drives the emulated drive the way a USB host stack does: CBW → data IN → CSW.
struct BOTHost {
    let drive: EmulatedCDROM
    var tag: UInt32 = 1

    mutating func command(_ cdb: [UInt8], dataLength: Int, inChunk: Int = 16_384) async -> (data: [UInt8], csw: [UInt8]) {
        var cbw = le32Bytes(0x4342_5355) + le32Bytes(tag) + le32Bytes(UInt32(dataLength))
        cbw += [0x80, 0, UInt8(cdb.count)]
        cbw += cdb + [UInt8](repeating: 0, count: 16 - cdb.count)
        tag += 1
        let out = await drive.bulk(endpoint: 0x02, data: cbw, length: 0)
        #expect(out.status == .success)
        var data: [UInt8] = []
        while data.count < dataLength {
            let chunk = await drive.bulk(endpoint: 0x81, data: [], length: min(inChunk, dataLength - data.count))
            #expect(chunk.status == .success)
            data += chunk.data
            if chunk.data.count < min(inChunk, dataLength - data.count + chunk.data.count) { break }  // short packet
        }
        let csw = await drive.bulk(endpoint: 0x81, data: [], length: 13).data
        return (data, csw)
    }
}

@Suite("Emulated CD-ROM")
struct EmulatedCDROMTests {
    func makeImage(blocks: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: blocks * 2048)
        for block in 0..<blocks {
            for i in 0..<2048 { bytes[block * 2048 + i] = UInt8(truncatingIfNeeded: block &* 31 &+ i) }
        }
        return bytes
    }

    @Test func descriptorsAndClassRequests() async {
        let drive = EmulatedCDROM(source: MemoryBlockSource(bytes: makeImage(blocks: 4)), name: "test.iso")
        let device = await drive.control(setup: USBControlSetup(requestType: 0x80, request: 6, value: 0x0100, index: 0, length: 18), data: [])
        #expect(device.data.count == 18)
        #expect(device.data[1] == 0x01)
        let config = await drive.control(setup: USBControlSetup(requestType: 0x80, request: 6, value: 0x0200, index: 0, length: 255), data: [])
        #expect(config.data.count == 32)
        #expect(config.data[9 + 5] == 0x08 && config.data[9 + 7] == 0x50)
        let shortConfig = await drive.control(setup: USBControlSetup(requestType: 0x80, request: 6, value: 0x0200, index: 0, length: 9), data: [])
        #expect(shortConfig.data.count == 9)
        let lun = await drive.control(setup: USBControlSetup(requestType: 0xA1, request: 0xFE, value: 0, index: 0, length: 1), data: [])
        #expect(lun.data == [0])
        let unknown = await drive.control(setup: USBControlSetup(requestType: 0x80, request: 6, value: 0x2200, index: 0, length: 64), data: [])
        #expect(unknown.status == .stall)
        let description = await drive.describe()
        #expect(description.interfaces.first?.interfaceClass == 0x08)
        #expect(description.endpoints.count == 2)
    }

    @Test func inquiryCapacityAndRead() async {
        let image = makeImage(blocks: 40)
        let drive = EmulatedCDROM(source: MemoryBlockSource(bytes: image), name: "test.iso")
        var host = BOTHost(drive: drive)

        let inquiry = await host.command([0x12, 0, 0, 0, 96, 0], dataLength: 96)
        #expect(inquiry.data.count == 36, "short data phase")
        #expect(inquiry.data[0] == 0x05)
        #expect(String(decoding: inquiry.data[16..<30], as: UTF8.self) == "Virtual CD-ROM")
        #expect(Array(inquiry.csw[0..<4]) == le32Bytes(0x5342_5355))
        #expect(le32(inquiry.csw, 8) == 60, "residue = 96 - 36")
        #expect(inquiry.csw[12] == 0)

        // First TEST UNIT READY reports UNIT ATTENTION, then ready.
        let tur1 = await host.command([0, 0, 0, 0, 0, 0], dataLength: 0)
        #expect(tur1.csw[12] == 1)
        let sense = await host.command([0x03, 0, 0, 0, 18, 0], dataLength: 18)
        #expect(sense.data[2] == 0x06 && sense.data[12] == 0x28)
        let tur2 = await host.command([0, 0, 0, 0, 0, 0], dataLength: 0)
        #expect(tur2.csw[12] == 0)

        let capacity = await host.command([0x25] + [UInt8](repeating: 0, count: 9), dataLength: 8)
        #expect(capacity.data == [0, 0, 0, 39, 0, 0, 0x08, 0x00])

        // READ(10) LBA 5, 3 blocks, fetched in 1000-byte IN chunks.
        let read = await host.command([0x28, 0, 0, 0, 0, 5, 0, 0, 3, 0], dataLength: 3 * 2048, inChunk: 1000)
        #expect(read.data == Array(image[(5 * 2048)..<(8 * 2048)]))
        #expect(read.csw[12] == 0)
        #expect(le32(read.csw, 8) == 0)

        let outOfRange = await host.command([0x28, 0, 0, 0, 0, 39, 0, 0, 2, 0], dataLength: 4096)
        #expect(outOfRange.data.isEmpty)
        #expect(outOfRange.csw[12] == 1)
        let rangeSense = await host.command([0x03, 0, 0, 0, 18, 0], dataLength: 18)
        #expect(rangeSense.data[2] == 0x05 && rangeSense.data[12] == 0x21)

        let toc = await host.command([0x43, 0, 0, 0, 0, 0, 0, 0x03, 0x24, 0], dataLength: 0x324)
        #expect(toc.data.count == 20)
        #expect(toc.data[6] == 1 && toc.data[14] == 0xAA)

        let unsupported = await host.command([0xEE, 0, 0, 0, 0, 0], dataLength: 0)
        #expect(unsupported.csw[12] == 1)
        let invalidSense = await host.command([0x03, 0, 0, 0, 18, 0], dataLength: 18)
        #expect(invalidSense.data[2] == 0x05 && invalidSense.data[12] == 0x20)

        let config = await host.command([0x46, 0, 0, 0, 0, 0, 0, 0, 255, 0], dataLength: 255)
        #expect(config.data[7] == 0x08, "CD-ROM profile for a small image")
        let event = await host.command([0x4A, 1, 0, 0, 0x10, 0, 0, 0, 8, 0], dataLength: 8)
        #expect(event.data[4] == 2, "new media reported once")
    }

    @Test func invalidCBWHaltsUntilReset() async {
        let drive = EmulatedCDROM(source: MemoryBlockSource(bytes: makeImage(blocks: 1)), name: "x")
        let bad = await drive.bulk(endpoint: 0x02, data: [UInt8](repeating: 0, count: 31), length: 0)
        #expect(bad.status == .stall)
        let stillHalted = await drive.bulk(endpoint: 0x02, data: [UInt8](repeating: 0, count: 31), length: 0)
        #expect(stillHalted.status == .stall)
        _ = await drive.control(setup: USBControlSetup(requestType: 0x21, request: 0xFF, value: 0, index: 0, length: 0), data: [])
        var host = BOTHost(drive: drive)
        let inquiry = await host.command([0x12, 0, 0, 0, 36, 0], dataLength: 36)
        #expect(inquiry.data.count == 36)
    }

    @Test func ejectNotifies() async {
        let box = EjectBox()
        let drive = EmulatedCDROM(source: MemoryBlockSource(bytes: makeImage(blocks: 1)), name: "x") { box.fire() }
        var host = BOTHost(drive: drive)
        _ = await host.command([0x1B, 0, 0, 0, 0x02, 0], dataLength: 0)
        #expect(box.fired)
        let tur = await host.command([0, 0, 0, 0, 0, 0], dataLength: 0)
        #expect(tur.csw[12] == 1)
    }
}

final class EjectBox: @unchecked Sendable {
    // Test-only; written once from the drive actor and read after an await.
    var fired = false
    func fire() { fired = true }
}
