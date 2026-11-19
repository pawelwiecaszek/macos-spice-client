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

## Remaining timing work

Playback START time is still discarded, and packet timestamps are not associated with
queued/rendered frames. Main-channel MultimediaClock remains independent of playback.
Queued milliseconds are not actual output delay. Next establish timestamp/frame anchors,
wrap/discontinuity/reset epochs, render/presentation delay and audio-route changes;
then make video scheduling consume that settled clock. Do not feed the requested
minimum into the clock as though it measured audio presentation.

The playback AsyncStream also mixes bounded newest audio/control events. Loss of control
events under overload and malformed/incomplete PCM frame handling need attention in
the timestamp/frame-lifecycle slice. Live same-guest A/V drift comparisons remain pending.
No installed application or PR is updated by this local slice.
