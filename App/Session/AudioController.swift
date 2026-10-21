import AppKit
import Observation
import SpiceKit
import os

/// Guest audio for one session (M7): plays the playback channel and, only when the user
/// switches the microphone on, feeds the record channel.
@MainActor
@Observable
final class AudioController {
    /// The guest is currently asking for microphone input.
    private(set) var guestWantsMicrophone = false
    /// The user allowed the microphone for this session (off by default).
    private(set) var microphoneEnabled = false
    private(set) var hasPlayback = false
    var errorMessage: String?

    @ObservationIgnored private let session: SpiceSession
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let player = AudioPlayer()
    @ObservationIgnored private let microphone = MicrophoneCapture()
    @ObservationIgnored private var decoder: OpusDecoder?
    @ObservationIgnored private var playbackChannels = 2
    @ObservationIgnored private var recordFormat: (channels: Int, frequency: Int)?
    @ObservationIgnored private var guestVolume: Float = 1
    @ObservationIgnored private var guestMuted = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let log = Logger(subsystem: "com.pawelwiecaszek.spiceclient", category: "audio")
    @ObservationIgnored private let opusDecode = OpusCodec.canDecode
    /// Microphone audio goes out as raw PCM: spice-server only accepts Opus input when it
    /// was built with Opus, which the client can't know in advance.
    @ObservationIgnored private let opusEncode = false
    @ObservationIgnored private let micSink: AsyncStream<MicrophoneCapture.Output>.Continuation
    @ObservationIgnored private let micStream: AsyncStream<MicrophoneCapture.Output>

    init(session: SpiceSession, settings: AppSettings) {
        self.session = session
        self.settings = settings
        // Packets from the audio thread are sent strictly in order by one consumer.
        (micStream, micSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(100))
    }

    /// Codecs/channels to advertise; call before connecting.
    var support: SpiceSession.AudioSupport {
        SpiceSession.AudioSupport(playback: settings.playGuestAudio, opusDecode: opusDecode,
                                  record: true, opusEncode: opusEncode)
    }

    func start() {
        let playback = session.playbackEvents
        tasks.append(Task { [weak self] in
            for await event in playback { self?.handle(event) }
        })
        let record = session.recordEvents
        tasks.append(Task { [weak self] in
            for await event in record { self?.handle(event) }
        })
        let session = self.session
        let microphoneOutput = micStream
        tasks.append(Task {
            for await output in microphoneOutput {
                switch output {
                case .raw(let bytes): await session.sendMicrophone(bytes, mode: .raw)
                case .opus(let frame): await session.sendMicrophone(frame, mode: .opus)
                }
            }
        })
    }

    func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        player.stop()
        microphone.stop()
    }

    // MARK: Playback

    private func handle(_ event: PlaybackEvent) {
        switch event {
        case .start(let channels, let frequency):
            playbackChannels = channels
            decoder = opusDecode && frequency == Int(OpusCodec.sampleRate) ? OpusDecoder(channels: channels) : nil
            do {
                try player.start(channels: channels, sampleRate: frequency)
                applyVolume()
                hasPlayback = true
            } catch {
                log.error("audio output failed: \(error.localizedDescription, privacy: .public)")
            }
        case .stop:
            player.stop()
            hasPlayback = false
        case .data(let mode, _, let bytes):
            switch mode {
            case .raw:
                let samples = bytes.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                player.enqueue(samples)
            case .opus:
                if let pcm = decoder?.decode(bytes) { player.enqueue(pcm) }
            default:
                break
            }
        case .volume(let level):
            guestVolume = level
            applyVolume()
        case .mute(let muted):
            guestMuted = muted
            applyVolume()
        case .latency:
            break
        }
    }

    private func applyVolume() {
        player.volume = guestMuted ? 0 : guestVolume
    }

    // MARK: Microphone

    private func handle(_ event: RecordEvent) {
        switch event {
        case .start(let channels, let frequency):
            recordFormat = (channels, frequency)
            guestWantsMicrophone = true
            if microphoneEnabled { startCapture() }
        case .stop:
            guestWantsMicrophone = false
            recordFormat = nil
            microphone.stop()
        case .volume, .mute:
            break  // the guest applies its own input gain
        }
    }

    /// Toolbar toggle. Turning it on asks for macOS microphone permission.
    func toggleMicrophone() {
        if microphoneEnabled {
            microphoneEnabled = false
            microphone.stop()
            return
        }
        Task {
            guard await MicrophoneCapture.requestPermission() else {
                errorMessage = String(localized: "MacOS Spice Client isn’t allowed to use the microphone. Allow it in System Settings › Privacy & Security › Microphone.")
                return
            }
            microphoneEnabled = true
            if guestWantsMicrophone { startCapture() }
        }
    }

    /// The user had the microphone on before a reconnect: keep it on (M8).
    func restoreMicrophone() {
        if !microphoneEnabled { toggleMicrophone() }
    }

    private func startCapture() {
        guard let format = recordFormat else { return }
        let sink = micSink
        do {
            try microphone.start(channels: format.channels, sampleRate: format.frequency, useOpus: opusEncode) { output in
                sink.yield(output)
            }
        } catch {
            errorMessage = String(localized: "The microphone couldn’t be started.")
            microphoneEnabled = false
        }
    }
}
