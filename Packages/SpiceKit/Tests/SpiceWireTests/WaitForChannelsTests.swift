import Testing
@testable import SpiceWire

struct WaitForChannelsTests {
    @Test func decodesPackedEntriesAndEmptyList() throws {
        #expect(try WaitForChannels(decoding: [0]).entries.isEmpty)
        var bytes = ByteWriter()
        bytes.writeU8(2)
        bytes.writeU8(ChannelType.display.rawValue); bytes.writeU8(1); bytes.writeU64(0x0102_0304_0506_0708)
        bytes.writeU8(ChannelType.cursor.rawValue); bytes.writeU8(0); bytes.writeU64(0)
        let decoded = try WaitForChannels(decoding: bytes.bytes)
        #expect(decoded.entries.count == 2)
        #expect(decoded.entries[0].channelID == 1)
        #expect(decoded.entries[0].messageSerial == 0x0102_0304_0506_0708)
    }

    @Test(arguments: [[], [1], [1, 2, 0, 1], [0, 99], [1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 99]])
    func rejectsTruncatedAndTrailingPayloads(_ bytes: [UInt8]) {
        #expect(throws: (any Error).self) { try WaitForChannels(decoding: bytes) }
    }
}
