import Foundation
import Testing
@testable import SpiceCodecs
import SpiceWire

/// One entry of `Fixtures/codecs/manifest.json`.
///
/// Fixtures were produced by encoding synthetic images with the reference SPICE encoder;
/// `fnv` is FNV-1a-64 over the expected BGRA pixels (`0xAARRGGBB`, little-endian bytes,
/// top-down). See `Tests/Fixtures/README.md`.
struct CodecFixture: Decodable, CustomTestStringConvertible, Sendable {
    let name: String
    let codec: String
    let width: Int
    let height: Int
    let fnv: String
    let palette: [UInt32]?

    var testDescription: String { name }

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/codecs")

    static let all: [CodecFixture] = {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([CodecFixture].self, from: data) else { return [] }
        return list
    }()

    static let quicFixtures = all.filter { $0.codec == "quic" }
    static let lzFixtures = all.filter { $0.codec == "lz" }

    func payload() throws -> [UInt8] {
        Array(try Data(contentsOf: Self.directory.appendingPathComponent("\(name).bin")))
    }
}

func fnv1a(_ pixels: [UInt32]) -> String {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for pixel in pixels {
        for shift in stride(from: 0, to: 32, by: 8) {
            hash ^= UInt64((pixel >> UInt32(shift)) & 0xFF)
            hash &*= 0x0000_0100_0000_01B3
        }
    }
    let hex = String(hash, radix: 16)
    return String(repeating: "0", count: 16 - hex.count) + hex
}

@Suite("Golden codec fixtures")
struct GoldenCodecTests {
    @Test func manifestLoaded() {
        #expect(CodecFixture.all.count >= 20)
    }

    @Test(arguments: CodecFixture.quicFixtures)
    func quic(_ fixture: CodecFixture) throws {
        let image = try QUICDecoder.decode(try fixture.payload()[...])
        #expect(image.width == fixture.width)
        #expect(image.height == fixture.height)
        #expect(fnv1a(image.pixels) == fixture.fnv)
    }

    @Test(arguments: CodecFixture.lzFixtures)
    func lz(_ fixture: CodecFixture) throws {
        let palette = fixture.palette.map { Palette(unique: 1, entries: $0) }
        let image = try LZDecoder.decode(try fixture.payload()[...], palette: palette)
        #expect(image.width == fixture.width)
        #expect(image.height == fixture.height)
        #expect(fnv1a(image.pixels) == fixture.fnv)
    }

    /// Truncated or bit-flipped streams must fail cleanly, never crash or hang.
    @Test(arguments: CodecFixture.all)
    func corruptedStreamsDoNotCrash(_ fixture: CodecFixture) throws {
        let original = try fixture.payload()
        var rng = SystemRandomNumberGenerator()
        let palette = fixture.palette.map { Palette(unique: 1, entries: $0) }
        for trial in 0..<40 {
            var bytes = original
            if trial % 2 == 0 {
                bytes = Array(bytes.prefix(Int.random(in: 0..<max(1, bytes.count), using: &rng)))
            } else if !bytes.isEmpty {
                for _ in 0..<4 {
                    let index = Int.random(in: 0..<bytes.count, using: &rng)
                    bytes[index] ^= UInt8.random(in: 1...255, using: &rng)
                }
            }
            if fixture.codec == "quic" {
                _ = try? QUICDecoder.decode(bytes[...])
            } else {
                _ = try? LZDecoder.decode(bytes[...], palette: palette)
            }
        }
    }

    @Test func quicRejectsBadMagic() {
        #expect(throws: CodecError.badMagic) { try QUICDecoder.decode([0, 0, 0, 0, 0, 0, 0, 0][...]) }
    }

    @Test func lzRequiresPaletteForPLT() throws {
        let fixture = try #require(CodecFixture.all.first { $0.name == "lz-plt8-desktop" })
        #expect(throws: CodecError.missingPalette) { try LZDecoder.decode(try fixture.payload()[...]) }
    }
}
