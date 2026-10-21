import Testing
@testable import SpiceWire

@Suite("SpiceWire")
struct SpiceWireTests {
    @Test func byteReaderReadsLittleEndian() throws {
        var reader = ByteReader([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0xFF])
        #expect(try reader.readU16() == 0x0201)
        #expect(try reader.readU32() == 0x0605_0403)
        #expect(try reader.readU8() == 0x07)
        #expect(throws: WireError.truncated(needed: 4, available: 2)) { try reader.readU32() }
    }

    @Test func byteWriterRoundTrip() throws {
        var writer = ByteWriter()
        writer.writeU8(0xAB)
        writer.writeU16(0x1234)
        writer.writeU32(0xDEAD_BEEF)
        writer.writeU64(0x0102_0304_0506_0708)
        writer.writeI32(-2)
        var reader = ByteReader(writer.bytes)
        #expect(try reader.readU8() == 0xAB)
        #expect(try reader.readU16() == 0x1234)
        #expect(try reader.readU32() == 0xDEAD_BEEF)
        #expect(try reader.readU64() == 0x0102_0304_0506_0708)
        #expect(try reader.readI32() == -2)
        #expect(reader.isAtEnd)
    }

    @Test func magicSpellsREDQ() {
        var writer = ByteWriter()
        writer.writeU32(spiceMagic)
        #expect(writer.bytes == Array("REDQ".utf8))
    }

    @Test func capabilitySet() {
        var caps = CapabilitySet(bits: [0, 3, 33])
        #expect(caps.words == [0b1001, 0b10])
        #expect(caps.contains(3))
        #expect(!caps.contains(2))
        caps.insert(2)
        #expect(caps.contains(2))
        #expect(!CapabilitySet().contains(0))
    }

    @Test func linkMessageLayout() throws {
        let message = LinkMessage(connectionID: 0x1122_3344, channelType: .display, channelID: 1,
                                  commonCaps: CapabilitySet(bits: [0, 1, 3]), channelCaps: CapabilitySet(bits: [5]))
        let bytes = message.encode()
        var reader = ByteReader(bytes)
        #expect(try reader.readU32() == spiceMagic)
        #expect(try reader.readU32() == 2)
        #expect(try reader.readU32() == 2)
        #expect(try reader.readU32() == 18 + 8)  // SpiceLinkMess + 2 caps words
        #expect(try reader.readU32() == 0x1122_3344)
        #expect(try reader.readU8() == ChannelType.display.rawValue)
        #expect(try reader.readU8() == 1)
        #expect(try reader.readU32() == 1)  // num_common_caps
        #expect(try reader.readU32() == 1)  // num_channel_caps
        #expect(try reader.readU32() == 18)  // caps_offset
        #expect(try reader.readU32() == 0b1011)
        #expect(try reader.readU32() == 0b10_0000)
        #expect(reader.isAtEnd)
    }

    @Test func linkReplyParsesCapsAtOffset() throws {
        var writer = ByteWriter()
        writer.writeU32(0)
        writer.writeBytes([UInt8](repeating: 0x42, count: 162))
        writer.writeU32(1)
        writer.writeU32(1)
        writer.writeU32(4 + 162 + 12)
        writer.writeU32(0b1011)
        writer.writeU32(0b1)
        let reply = try LinkReply(decoding: writer.bytes)
        #expect(reply.linkError == .ok)
        #expect(reply.publicKey.count == 162)
        #expect(reply.commonCaps.contains(CommonCapability.miniHeader.rawValue))
        #expect(reply.channelCaps.contains(0))
    }

    @Test(arguments: [
        (UInt16(0x1E), false, UInt32(0x1E)),  // A press
        (0x1E, true, 0x9E),  // A release
        (0x148, false, 0x48E0),  // Up arrow: E0 48
        (0x148, true, 0xC8E0),  // Up arrow release: E0 C8
        (0x15B, false, 0x5BE0),  // Left Windows
    ])
    func scancodeEncoding(code: UInt16, release: Bool, expected: UInt32) {
        #expect(InputsClientEncoder.wireScancode(code, release: release) == expected)
    }

    @Test func mainInitDecoding() throws {
        var writer = ByteWriter()
        for value: UInt32 in [7, 1, 3, 1, 1, 10, 12345, 0] { writer.writeU32(value) }
        let message = try MainInit(decoding: writer.bytes)
        #expect(message.sessionID == 7)
        #expect(message.supportedMouseModes == [.server, .client])
        #expect(message.currentMouseMode == .server)
        #expect(message.agentConnected)
        #expect(message.agentTokens == 10)
    }

    @Test func drawCopyWithBitmapPointer() throws {
        // DisplayBase (surface 0, box 0,0-2,1, no clip) + Copy with an inline 2x1 32-bit bitmap.
        var w = ByteWriter()
        w.writeU32(0)
        for v: Int32 in [0, 0, 1, 2] { w.writeI32(v) }  // top, left, bottom, right
        w.writeU8(0)  // clip none
        let pointerPosition = w.count
        w.writeU32(0)  // src_bitmap (patched)
        for v: Int32 in [0, 0, 1, 2] { w.writeI32(v) }  // src_area
        w.writeU16(Ropd.opPut.rawValue)
        w.writeU8(ScaleMode.nearest.rawValue)
        w.writeU8(0)  // mask flags
        w.writeI32(0); w.writeI32(0)  // mask pos
        w.writeU32(0)  // mask bitmap null
        let imageOffset = UInt32(w.count)
        w.writeU64(99)  // id
        w.writeU8(ImageType.bitmap.rawValue)
        w.writeU8(0)
        w.writeU32(2); w.writeU32(1)
        w.writeU8(BitmapFormat.thirtyTwoBit.rawValue)
        w.writeU8(BitmapFlags.topDown.rawValue)
        w.writeU32(2); w.writeU32(1); w.writeU32(8)
        w.writeU32(0)  // palette pointer
        w.writeBytes([0x10, 0x20, 0x30, 0x00, 0x40, 0x50, 0x60, 0x00])
        var bytes = w.bytes
        bytes[pointerPosition] = UInt8(imageOffset & 0xFF)
        bytes[pointerPosition + 1] = UInt8(imageOffset >> 8)

        let copy = try DrawCopy(decoding: bytes)
        #expect(copy.base.box == Rect(left: 0, top: 0, right: 2, bottom: 1))
        let image = try #require(copy.source)
        #expect(image.descriptor.id == 99)
        guard case .bitmap(let bitmap) = image.payload else {
            Issue.record("expected bitmap")
            return
        }
        #expect(bitmap.width == 2 && bitmap.height == 1 && bitmap.stride == 8)
        #expect(Array(bitmap.data) == [0x10, 0x20, 0x30, 0x00, 0x40, 0x50, 0x60, 0x00])
        #expect(copy.mask.bitmap == nil)
    }

    @Test func hostileClipCountIsRejected() {
        var w = ByteWriter()
        w.writeU32(0)
        for _ in 0..<4 { w.writeI32(0) }
        w.writeU8(1)
        w.writeU32(0xFFFF_FFFF)
        #expect(throws: WireError.self) { try CopyBits(decoding: w.bytes) }
    }

    @Test func imagePointerOutOfRange() {
        var w = ByteWriter()
        w.writeU32(0)
        for _ in 0..<4 { w.writeI32(0) }
        w.writeU8(0)
        w.writeU32(0xFFFF)  // pointer past end
        w.writeBytes([UInt8](repeating: 0, count: 32))
        #expect(throws: WireError.badOffset(0xFFFF)) { try DrawCopy(decoding: w.bytes) }
    }

    /// Random garbage must never crash any decoder.
    @Test func fuzzDecoders() {
        var state: UInt64 = 0xC0FFEE
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        for _ in 0..<3000 {
            let count = Int(next() % 200)
            let bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: next()) }
            _ = try? DrawCopy(decoding: bytes)
            _ = try? DrawFill(decoding: bytes)
            _ = try? DrawAlphaBlend(decoding: bytes)
            _ = try? DrawTransparent(decoding: bytes)
            _ = try? StreamCreate(decoding: bytes)
            _ = try? StreamData(decoding: bytes, sized: true)
            _ = try? MonitorsConfig(decoding: bytes)
            _ = try? CursorSet(decoding: bytes)
            _ = try? ChannelsList(decoding: bytes)
            _ = try? LinkReply(decoding: bytes)
            _ = try? Notify(decoding: bytes)
        }
    }
}
