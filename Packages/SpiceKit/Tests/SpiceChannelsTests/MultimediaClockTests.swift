import Synchronization
import Testing
@testable import SpiceChannels

struct MultimediaClockTests {
    @Test func mainTimeAdvancesAndZeroIsAValidAnchor() {
        let time = ManualTime()
        let clock = MultimediaClock(now: { time.now })
        #expect(clock.now == nil)
        clock.set(0)
        #expect(clock.now == 0)
        time.advance(.milliseconds(10))
        #expect(clock.now == 10)
    }

    @Test func freshAudioOverridesMainWhileMainFallbackKeepsUpdating() {
        let time = ManualTime()
        let clock = MultimediaClock(now: { time.now })
        clock.set(1000)
        let epoch = clock.beginAudio()
        #expect(clock.updateAudio(time: 2000, epoch: epoch))
        time.advance(.milliseconds(100))
        clock.set(3000)
        #expect(clock.now == 2100)
        time.advance(.milliseconds(150))
        #expect(clock.now == 2250)
        time.advance(.milliseconds(1))
        #expect(clock.now == 3151, "Audio expiry uses the latest independent main sync")
    }

    @Test func staleAudioWithoutMainBecomesUnknownRatherThanZero() {
        let time = ManualTime()
        let clock = MultimediaClock(now: { time.now })
        let epoch = clock.beginAudio()
        #expect(clock.now == nil)
        #expect(clock.updateAudio(time: 0, epoch: epoch))
        #expect(clock.now == 0)
        time.advance(.milliseconds(251))
        #expect(clock.now == nil)
    }

    @Test func observationsUseTheirOriginalInstantAndRejectFutureStaleOrOlderSamples() {
        let time = ManualTime()
        let clock = MultimediaClock(now: { time.now })
        let epoch = clock.beginAudio()
        let old = time.now
        #expect(clock.updateAudio(time: 1000, epoch: epoch, at: old))
        time.advance(.milliseconds(10))
        #expect(clock.updateAudio(time: 2000, epoch: epoch))
        #expect(!clock.updateAudio(time: 9000, epoch: epoch, at: old))
        #expect(!clock.updateAudio(time: 9000, epoch: epoch, at: time.now.advanced(by: .milliseconds(1))))
        #expect(clock.now == 2000)
        time.advance(.milliseconds(251))
        #expect(!clock.updateAudio(time: 9000, epoch: epoch, at: old))
        #expect(clock.now == nil)
    }

    @Test func reofferingAnOldAnchorDoesNotRefreshItsDeadline() {
        let time = ManualTime()
        let clock = MultimediaClock(now: { time.now })
        let epoch = clock.beginAudio()
        let at = time.now
        #expect(clock.updateAudio(time: 1000, epoch: epoch, at: at))
        time.advance(.milliseconds(200))
        #expect(clock.updateAudio(time: 1000, epoch: epoch, at: at))
        #expect(clock.now == 1200)
        time.advance(.milliseconds(51))
        #expect(clock.now == nil)
    }

    @Test func invalidationFallsBackAndOnlyNewObservationsCanRecover() {
        let time = ManualTime()
        let clock = MultimediaClock(now: { time.now })
        clock.set(1000)
        let epoch = clock.beginAudio()
        let old = time.now
        #expect(clock.updateAudio(time: 2000, epoch: epoch))
        time.advance(.milliseconds(10))
        #expect(clock.invalidateAudio(epoch: epoch))
        #expect(clock.now == 1010)
        #expect(!clock.updateAudio(time: 2000, epoch: epoch, at: old))
        time.advance(.milliseconds(1))
        #expect(clock.updateAudio(time: 3000, epoch: epoch))
        #expect(clock.now == 3000)
    }

    @Test func oldEpochsCannotUpdateInvalidateOrEndAReplacement() {
        let time = ManualTime()
        let clock = MultimediaClock(now: { time.now })
        clock.set(1000)
        let first = clock.beginAudio()
        #expect(clock.updateAudio(time: 2000, epoch: first))
        let second = clock.beginAudio()
        #expect(first != second && clock.now == 1000)
        #expect(!clock.updateAudio(time: 9000, epoch: first))
        #expect(!clock.invalidateAudio(epoch: first))
        #expect(!clock.endAudio(epoch: first))
        #expect(clock.updateAudio(time: 3000, epoch: second))
        #expect(clock.now == 3000)
        #expect(clock.endAudio(epoch: second))
        #expect(clock.now == 1000)
        #expect(!clock.updateAudio(time: 9000, epoch: second))
    }

    @Test func resetClearsBothSourcesAndRetiresTheOldProducer() {
        let time = ManualTime()
        let clock = MultimediaClock(now: { time.now })
        clock.set(1000)
        let old = clock.beginAudio()
        #expect(clock.updateAudio(time: 2000, epoch: old))
        clock.reset()
        #expect(clock.now == nil)
        #expect(!clock.updateAudio(time: 9000, epoch: old))
        let fresh = clock.beginAudio()
        #expect(fresh != old)
        #expect(!clock.updateAudio(time: 9000, epoch: old))
        clock.set(42)
        #expect(clock.now == 42)
    }

    @Test func bothSourcesAdvanceAcrossUnsignedMillisecondWrap() {
        let time = ManualTime()
        let clock = MultimediaClock(now: { time.now })
        clock.set(UInt32.max - 5)
        time.advance(.milliseconds(20))
        #expect(clock.now == 14)
        let epoch = clock.beginAudio()
        #expect(clock.updateAudio(time: UInt32.max - 2, epoch: epoch))
        time.advance(.milliseconds(5))
        #expect(clock.now == 2)
    }

    @Test func longMainIntervalsUseWrappingArithmeticWithoutSignedOverflow() {
        let time = ManualTime()
        let clock = MultimediaClock(now: { time.now })
        clock.set(42)
        time.advance(.seconds(10_000_000))
        #expect(clock.now == 42 &+ (UInt32(10_000_000) &* 1000))
    }

    @Test func concurrentMainUpdatesCannotDisplaceFreshAudio() async {
        let time = ManualTime()
        let clock = MultimediaClock(now: { time.now })
        let epoch = clock.beginAudio()
        #expect(clock.updateAudio(time: 2000, epoch: epoch))
        await withTaskGroup(of: Void.self) { group in
            for value in 0..<100 {
                group.addTask {
                    clock.set(UInt32(value))
                    #expect(clock.now == 2000)
                }
            }
        }
        #expect(clock.now == 2000)
    }

    @Test func playbackDelayExpiresAndClearsWithItsAuthority() {
        let time = ManualTime()
        let clock = MultimediaClock(now: { time.now })
        let epoch = clock.beginAudio()
        #expect(clock.audioDelayMilliseconds == nil)
        #expect(clock.updateAudio(time: 100, epoch: epoch, delayMilliseconds: 80))
        #expect(clock.audioDelayMilliseconds == 80)
        time.advance(.milliseconds(251))
        #expect(clock.audioDelayMilliseconds == nil)
        #expect(clock.updateAudio(time: 351, epoch: epoch, delayMilliseconds: 90))
        #expect(clock.invalidateAudio(epoch: epoch))
        #expect(clock.audioDelayMilliseconds == nil)
        #expect(clock.updateAudio(time: 351, epoch: epoch, delayMilliseconds: 100))
        clock.reset()
        #expect(clock.audioDelayMilliseconds == nil)
    }

    private final class ManualTime: Sendable {
        private let instant = Mutex(ContinuousClock.now)
        var now: ContinuousClock.Instant { instant.withLock { $0 } }
        func advance(_ duration: Duration) { instant.withLock { $0 = $0.advanced(by: duration) } }
    }
}
