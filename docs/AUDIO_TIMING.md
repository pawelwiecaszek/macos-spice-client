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
the samples. The implementation does not update MultimediaClock from this snapshot yet.

Hardware-free timeline/ring regressions cover partial consumption, trimming, overwrite,
44.1 kHz drift, wrap, discontinuities, saturation, unknown regions, hostile counts,
whole-frame rejection, underrun/rebuffering and stale generations. Channel tests verify
START and DATA timestamps. Audio hardware and route/presentation feedback remain separate
gates; no live A/V synchronization is claimed.

## Remaining timing work

Next settle audio/control event delivery under overload, then associate source-render
positions with actual presentation delay, timestamp freshness and audio-route/rate epochs.
The playback AsyncStream still mixes bounded newest audio/control events, so control
loss under overload needs attention before clock feedback. Main-channel MultimediaClock
remains independent of playback, and queued milliseconds are not actual output delay.
Do not feed requested minimum buffering or a stale source-render snapshot into it as
though either measured presentation. Video scheduling must consume the settled clock
before claiming A/V sync. Live same-guest drift comparisons remain pending.
No installed application or PR is updated by this local slice.
