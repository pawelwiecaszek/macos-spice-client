import Foundation
import Testing
@testable import AudioHost

@Suite("Audio host")
struct AudioHostTests {
    /// 440 Hz stereo sine at 48 kHz.
    static func tone(frames: Int, offset: Int = 0) -> [Int16] {
        (0..<frames).flatMap { i -> [Int16] in
            let v = Int16(sin(Double(i + offset) * 2 * .pi * 440 / 48_000) * 12_000)
            return [v, v]
        }
    }

    @Test func opusRoundTripWhenAvailable() throws {
        guard let encoder = OpusEncoder(channels: 2), let decoder = OpusDecoder(channels: 2) else {
            // AudioToolbox without Opus: the client simply doesn't advertise it.
            return
        }
        var decodedFrames = 0
        var energy = 0.0
        for packet in 0..<20 {
            let pcm = Self.tone(frames: encoder.frameSize, offset: packet * encoder.frameSize)
            let frame = try #require(encoder.encode(pcm))
            #expect(!frame.isEmpty && frame.count < 1500)
            if let out = decoder.decode(frame) {
                decodedFrames += out.count / 2
                energy += out.reduce(0.0) { $0 + Double($1) * Double($1) }
            }
        }
        // The decoder has a little priming delay; nearly all frames must come out.
        #expect(decodedFrames >= encoder.frameSize * 15, "decoded \(decodedFrames) frames")
        #expect(energy > 0, "decoded audio must not be silent")
    }

    @Test func decoderRejectsGarbage() {
        guard let decoder = OpusDecoder(channels: 2) else { return }
        #expect(decoder.decode([]) == nil)
        #expect(decoder.decode([UInt8](repeating: 0xFF, count: 4000)) == nil)
    }

    @Test func playerBoundsLatency() throws {
        let player = AudioPlayer()
        try? player.start(channels: 2, sampleRate: 48_000)  // may fail without an output device
        defer { player.stop() }
        guard player.bufferedMilliseconds == 0 else { return }
        // 1 s of audio arrives at once: latency is cut back to the start threshold.
        player.enqueue(Self.tone(frames: 48_000))
        #expect(player.bufferedMilliseconds <= 250)
    }
}
