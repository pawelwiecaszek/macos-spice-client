import Foundation
import Testing
@testable import SpiceCodecs

@Suite("LZ4")
struct LZ4Tests {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/codecs")

    @Test func decodesReferenceBlock() throws {
        let compressed = Array(try Data(contentsOf: directory.appendingPathComponent("lz4-block.bin")))
        let expected = Array(try Data(contentsOf: directory.appendingPathComponent("lz4-block.expected")))
        #expect(try LZ4Decoder.decompress(compressed[...], uncompressedSize: expected.count) == expected)
        #expect(throws: CodecError.self) { try LZ4Decoder.decompress(compressed[...], uncompressedSize: expected.count - 1) }
    }

    @Test func overlappingMatchAndHostileInput() throws {
        // "a" literal then match offset 1 length 9 → ten "a" + trailing literal "b".
        let block: [UInt8] = [0x15, 0x61, 0x01, 0x00, 0x10, 0x62]
        #expect(try LZ4Decoder.decompress(block[...], uncompressedSize: 11) == Array("aaaaaaaaaab".utf8))
        #expect(throws: CodecError.self) { try LZ4Decoder.decompress([0x10, 0x61, 0x05, 0x00][...], uncompressedSize: 10) }
        for length in 0..<40 {
            _ = try? LZ4Decoder.decompress([UInt8](repeating: 0xFF, count: length)[...], uncompressedSize: 100)
        }
    }
}
