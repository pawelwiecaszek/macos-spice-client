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

    @Test func canvasRop3Throughput() {
        var surface = PixelBuffer(width: 1920, height: 1080)
        let source = PixelBuffer(width: 1920, height: 1080, fill: 0xFF12_3456)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<10 {
                surface.rop3(from: source, sourceArea: source.bounds, brush: .color(0x0011_2233),
                             box: surface.bounds, clip: .none, rop: 0x96)
            }
        }
        #expect(surface[0, 0] == 0xFF00_0000)
        print("Benchmark canvas ROP3 1080p x10: \(elapsed)")
    }

    @Test func cosmeticStrokeThroughput() throws {
        var surface = PixelBuffer(width: 1920, height: 1080)
        let path = StrokePath(segments: [.init(flags: [.begin, .end], points: [
            .init(x: 0, y: 0), .init(x: 1919 * 16, y: 1079 * 16)
        ])])
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            for _ in 0..<100 {
                try surface.strokeSolid(path: path, brush: .color(0x00FF_FFFF), box: surface.bounds, clip: .none, mode: .opPut)
            }
        }
        print("Benchmark cosmetic strokes 1080p x100: \(elapsed)")
    }

    @Test func cubicStrokeThroughput() throws {
        var surface = PixelBuffer(width: 65, height: 65)
        let path = StrokePath(segments: [.init(flags: [.begin, .end, .bezier], points: [
            .init(x: 0, y: 0), .init(x: 0, y: 1024), .init(x: 1024, y: 1024), .init(x: 1024, y: 0)
        ])])
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            for _ in 0..<100 {
                try surface.strokeSolid(path: path, brush: .color(.max), box: surface.bounds, clip: .none, mode: .opPut)
            }
        }
        print("Benchmark cubic strokes x100: \(elapsed)")
    }

    @Test func styledAxisStrokeThroughput() throws {
        var surface = PixelBuffer(width: 1920, height: 1080)
        let path = StrokePath(segments: [.init(flags: [.begin,.end], points: [
            .init(x: 0, y: 0), .init(x: 1919 * 16, y: 0), .init(x: 1919 * 16, y: 1079 * 16)
        ])])
        let attributes = StrokeAttributes(flags: 8, style: [32,32])
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            for _ in 0..<100 {
                try surface.strokeStyled(path: path, attributes: attributes, brush: .color(.max),
                                         box: surface.bounds, clip: .none, mode: .opXor)
            }
        }
        print("Benchmark styled axis strokes 1080p x100: \(elapsed)")
    }

}
