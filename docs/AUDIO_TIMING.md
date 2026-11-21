# C3 audio: bounded server-directed buffering

First audio slice: consume the playback channel's minimum-latency request instead of
discarding it. This is a minimum buffer target, not measured output delay or A/V sync.
The [official playback API](https://www.spice-space.org/api/spice-gtk/SpicePlaybackChannel.html)
defines min-latency as playback minimum buffer size in milliseconds.

## Policy and lifecycle

The existing local default remains 60 ms prebuffer and 250 ms high-water. Server
requests raise the target up to a local 750 ms safety cap; the high-water becomes
max(250, target + 190) ms, nominally at most 940 ms before whole-frame rounding.
Storage remains one second of PCM. Requests
above the cap cannot be fully honored; the cap is client resource policy, not a claim
that the larger server requirement was satisfied.

Targets round upward to complete interleaved channel frames. Formats are validated
before capacity arithmetic: 1–8 channels, 8–192 kHz. An explicit increase can rebuffer
when the queue is short. Repeating or reducing a target does not interrupt steady
playback merely because normal draining lowered queue depth. Underruns retain the
existing silence/rebuffer behavior; excess queues drop old whole frames to the target.

The app retains requests arriving before START, passes the latest request to player
configuration, and applies updates to an active ring. STOP/session stop clear the
pending request and decoder/playback state. The official spice-gtk 0.42 release resets
its minimum to default on START; this client clears it on STOP, retaining its own
60 ms default for the next playback. A failed engine start cleans up its ring
and node. A stopped player's setter retains no pending policy. Reconnect creates a
fresh controller/player/session as before.

Hardware-free policy/ring tests cover defaults, zero/extreme requests, supported rates,
frame rounding, capacity relationships, explicit raises, repeated/lowered targets and
high-water wrap/trimming. A channel test locks request ordering and unsigned values.
App wiring is reviewed and Release-built; live audio output is a separate gate.

## Packet-to-rendered-frame timeline

Playback START timestamps now survive channel delivery and are retained as stream
metadata. DATA/MODE packet timestamps accompany decoded PCM into a bounded frame
metadata FIFO. They are frame-boundary times in SPICE's wrapping u32 millisecond
domain, not host dates or device presentation times. Untimed legacy enqueue remains
supported, but its output has no fabricated timestamp estimate.

A fixed 2,048-slot metadata ring tracks at most one second of queued frames. It uses
an original shared timestamp anchor plus absolute frame offsets, avoiding per-packet
rounding drift at fractional rates. Timestamp quantization within one millisecond is
accepted. Larger forward/backward jumps and duplicate long packets establish a new
timing epoch and invalidate older queued timing without silently discarding PCM.
Unknown regions, epoch crossings and metadata saturation produce no estimate until
a fresh known region is actually rendered. Oversized metadata appends trim prefixes
analytically; hostile integer counts reject before changing the queue.

PCM and metadata trim together for capacity overwrite and high-water drops. Partial
channel frames reject as whole packets; the app also rejects partial raw S16 byte
frames. A local decoded-packet sample cap bounds copying. Real render callbacks consume
only frames actually supplied to the source node. Prebuffer silence, underruns and
rebuffering do not advance a reported position. Old render generations cannot consume
a replacement queue.

`AudioPlayer.renderedPosition` is an optional snapshot of a complete source-render
block: server start/end times, frame count/rate, playback/timeline epochs and an optional
Core Audio host-time anchor for the first frame. Zero is a valid timestamp; missing
or invalid host time remains nil. This is not proof that the playback device presented
the samples. Presentation calibration below converts valid snapshots into multimedia
clock observations.

Hardware-free timeline/ring regressions cover partial consumption, trimming, overwrite,
44.1 kHz drift, wrap, discontinuities, saturation, unknown regions, hostile counts,
whole-frame rejection, underrun/rebuffering and stale generations. Channel tests verify
START and DATA timestamps. Audio hardware and route/presentation feedback remain separate
gates; no live A/V synchronization is claimed.

## Control-safe playback delivery

Playback delivery now uses one bounded mailbox rather than a newest-only event
stream that can silently evict START/STOP. Its pull-based AsyncStream adds no second
queue. Defaults cap retained events at 500, external controls at 64 and encoded audio
at 8 MiB; an individual packet is at most 64 KiB. Producer delivery resumes waiting
consumers outside the mutex and does not launch a task per packet.

Audio pressure removes all queued DATA and older loss markers, preserving the order
of retained START/STOP, volume, mute and minimum-buffer events. One discontinuity marker
precedes subsequent DATA. The app clears queued PCM, invalidates frame timing and
recreates an active Opus decoder before accepting fresh packets. Output format and
minimum-buffer policy remain active, and fresh frames establish a new timing epoch.

When controls plus required markers cannot fit, or a packet exceeds the supported
bound, delivery ends explicitly with STOP then EOF. The optional playback channel
terminates; this does not shut down the VDI. Delivery-limit failures retain a typed
packet/control/event-limit reason and reach session diagnostics instead of being
suppressed as intentional cancellation. A new playback channel/session may be
needed to resume audio after that failure. Normal producer close is idempotent and
also stops playback; canceled consumers release pending continuations. The app's
non-canceled EOF path stops output even without a separate server STOP message.

## Presentation calibration and video deadlines

The source node's first-frame host time plus its downstream
`outputPresentationLatency` estimates when that frame reaches the output. The client
subtracts that latency once from elapsed host time; requested buffering and queued
PCM are not added to this clock correction. Zero/invalid latency, old render blocks,
underruns and discontinuities invalidate audio authority. Fresh observations expire
after 250 ms; independent main-channel time remains the fallback. Epoch leases reject
callbacks from stopped/replaced playback. Output configuration changes invalidate the
ring immediately and rebuild the engine on its owner, with bounded retry frequency.

Video decoding preserves receive order. Decoded future frames wait in bounded queues
(32 frames per stream, 256 MiB aggregate); nearest deadlines survive capacity pressure.
One timer handles pending deadlines and reports. Due frames present in timestamp order,
old due frames are superseded, frames more than 100 ms late are dropped, and timestamps
more than 2.5 seconds ahead are rejected. These are local resource policies. Missing
clock information preserves immediate presentation. Stream destruction, surface
replacement, reset and close retire pending frames. Reports count arrivals and late
drops separately; unknown delay is never invented as zero. Playback delay includes the
known queued endpoint relative to calibrated audible time, or uses the unavailable
sentinel. Record volume is no longer advertised without an implemented capture handler.

Automated coverage includes wrapping timestamps, stale observations, route invalidation,
permission cancellation, bounded queues, sustained arrivals, control loss, stream
replacement, nonblocking PING and report activation/timeout behavior. Live same-guest
A/V drift comparisons, output-route changes and microphone checks remain pending;
these tests do not establish acoustic synchronization or complete SPICE parity.

Presentation references: [source render block](https://developer.apple.com/documentation/avfaudio/avaudiosourcenoderenderblock),
[downstream latency](https://developer.apple.com/documentation/avfaudio/avaudionode/outputpresentationlatency),
[engine configuration changes](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification).

## Media capability contract

| Advertised capability | Handler / evidence | Limit |
| --- | --- | --- |
| Playback volume | `AudioVolume` → `AudioController.applyVolume`; `AudioChannelTests` | Guest volume/mute changes local mixer output. |
| Playback latency | `AudioBufferingPolicy`; `AudioBufferingTests` | Bounded minimum target, never substituted for measured output delay. |
| Playback Opus | `OpusCodec.canDecode` gates advertisement; `OpusDecoder` | Decoder must be available; PCM remains supported. |
| Record Opus | `AudioController.support` passes false | App sends raw PCM; optional library encoder does not imply app negotiation. |
| Record volume | No longer advertised; `AudioChannelTests` | No capture gain/mute handler. |
| Sized stream | `StreamData.resize` destination; display wire/decoder tests | Surface/clip bounds remain enforced. |
| Stream report | `VideoStreamReports`; `VideoTimingTests`, `VideoSchedulingTests` | Arrivals, late drops, activation identity and timeout; unavailable audio delay uses sentinel. |
| MJPEG / H.264 / H.265 | `DisplayChannel.videoCodecs`, `VideoDecoderTests` | ImageIO MJPEG and runtime-supported hardware decoders only; VP8/VP9 unadvertised. |
| Multi-codec / preferred codec | Display initialization codec list | List derived from the same runtime decoder selection. |
| Preferred compression / LZ4 | Display initialization and `ImageResolver` | Existing still-image codec/replay tests; unchanged by media scheduling. |
| Monitor configuration | Display monitor event decoding | Negotiated wire support exists; app head presentation remains C4 work. |

Other channel capabilities retain their existing handlers and security gates. This
media change does not claim new USB, agent, migration or multi-head functionality.
