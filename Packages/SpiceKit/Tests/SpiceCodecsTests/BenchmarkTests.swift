import Testing
@testable import SpiceCodecs
import SpiceWire

/// Rough throughput numbers; run with `swift test -c release --filter Benchmark`.
/// They only print timings (no thresholds), so they never flake in CI.
@Suite("Benchmark")
struct BenchmarkTests {
    @Test func quicAndLZThroughput() throws {
        for name in ["quic-rgb32-desktop", "lz-rgb32-desktop-td"] {
            let fixture = try #require(CodecFixture.all.first { $0.name == name })
            let payload = try fixture.payload()
            let iterations = 20
            let clock = ContinuousClock()
            let elapsed = try clock.measure {
                for _ in 0..<iterations {
                    if fixture.codec == "quic" {
                        _ = try QUICDecoder.decode(payload[...])
                    } else {
                        _ = try LZDecoder.decode(payload[...])
                    }
                }
            }
            let pixels = Double(fixture.width * fixture.height * iterations)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print("Benchmark \(name): \(Int(pixels / seconds / 1_000_000)) Mpixel/s")
        }
    }

    @Test func canvasCopyThroughput() {
        var surface = PixelBuffer(width: 1920, height: 1080)
        let source = PixelBuffer(width: 1920, height: 1080, fill: 0xFF12_3456)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<10 {
                surface.copy(from: source, sourceArea: source.bounds, box: surface.bounds, clip: .none)
            }
        }
        print("Benchmark canvas copy 1080p x10: \(elapsed)")
    }
}
