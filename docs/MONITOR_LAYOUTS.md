# C4: monitor presentation

## Presentation

Display-channel, surface and monitor identities remain separate. Channel zero can
present up to four heads of its primary surface in independent windows. Additional
display channels retain the established single-head-zero mapping. Each channel owns
one upload texture; its head windows share that texture and sample bounded regions.
Dirty updates are uploaded once and return one update credit, independent of head count.

Monitor-local absolute input uses the head ID on channel zero and channel ID on other
single-head channels. Surface crop offsets are not added to pointer coordinates.
Server-mode cursor overlays use surface coordinates and are clipped to the head.
The existing session cursor stream lacks additional-channel identity, so server-mode
overlays on nonzero channels remain unavailable. Client-mode cursor shapes are shared.

Single-head surface cropping starts at zero, matching the established reference
behavior even when its x/y describe placement elsewhere in the desktop. Multi-head
crops use advertised offsets. Disabled heads create no windows; an all-disabled
configuration blanks the primary presentation and rejects input. Unsupported bounds,
surface mappings or monitor IDs show the whole primary surface in view-only mode.
Ambiguous input IDs across mixed channel/head arrangements reject input on the
ambiguous views. The main toolbar explains view-only fallback.

Layout/surface replacement rebinds shared textures and retires removed windows.
Destroyed/stopped sources reject late updates. A manually closed head is recreated
with a fresh view/render loop if a later layout offers it again. Hotkeys act on the
focused head; explicit Release Cursor releases input across the session. Clipboard
activity recognizes any of the session's key windows.

## Resource policy and remaining work

The wire decoder accepts at most 64 metadata records and requires exact payload
length and unique IDs. Presentation accepts at most four heads per channel within
the existing four-channel bound. No texture is allocated from head dimensions;
existing surface allocation limits remain authoritative. Unknown flags are retained.
`max_allowed` is independent metadata, not assumed equal to count.

Complete-set guest resize is now implemented for known, validated layouts. Each
request retains all enabled and disabled heads, including closed-window heads. A
changed head keeps its anchor; heads at/beyond its old right/bottom edges move by the
size delta, retaining their sizes and gaps. Overlap, signed overflow and combined
surface dimension/pixel-budget violations refuse the request. Between server
metadata updates, the most recent desired set is retained while consecutive window edits merge.
New topology retires that intent. Closing a head does not disable its guest monitor.

Peer monitor-configuration support is required; positions and sparse IDs require
the corresponding agent capabilities. Sparse requests preserve array slot identity
with zero-sized disabled entries. Typed sets contain at most 16 explicit entries and
encode at most 256 slots. No implicit clone/provisioning or monitor-enable action is
introduced. Unknown/unsupported channels, missing initial monitor metadata, mirrored
or overlapping layouts, and nonzero-channel multihead mappings scale locally.
Separate-channel peers with no monitor-config support keep the legacy left-to-right
arrangement; explicit global positions are preserved when provided. Separate-channel
peers reporting overlapping local origins cannot yet be resized automatically.

Per-display topology authorization is invalidated in the wire reader before metadata
is delivered to the app. Complete-set requests require current observations from every
expected channel, a main-channel lifecycle/channel-set observation, and a UI-intent
observation. Token-starved requests coalesce to one pending set and recheck all
observations before transmission begins. Topology change, agent replacement, a newer
resize, stop and close retire stale queued work even before UI callbacks are consumed.
An agent message already started must finish its framing; its effects cannot be
revoked by later metadata. A newly advertised channel set after initial channel
opening suppresses resize until reconnect rather than guessing unlinked displays.

Automated tests cover wire bounds, crop geometry, texture sharing and pixel uploads,
local input/Retina/letterbox mapping, disabled/unsupported layouts, mixed-ID admission,
configuration-before-surface, unplug, surface destruction, close/reoffer and stop.
Full-set regressions cover disabled/sparse slots, position capability gates, reflow,
closed heads, simultaneous edits, initial-layout readiness, wire-to-UI callback lag,
agent/channel replacement, token starvation and bounded request coalescing.
The user accepted single- and two-virtual-monitor behavior on the tested deployment
using build `0098d64`: both head windows displayed correctly, input worked, and resizing
one preserved the other. Single-monitor checks also passed resizing, corner pointer
alignment, keyboard input, fullscreen/windowed transitions and close/reconnect. This
report does not identify the negotiated channel arrangement or establish separate
Linux/shared-surface and Windows/separate-channel coverage; broader guest/driver and
physical hot-unplug validation remains pending. One physical Mac monitor can host several guest-head windows; the guest
must still expose the corresponding virtual monitors. No VM configuration is changed
by this implementation.

## Protocol evidence

The implementation follows semantics, without copying rendering implementation:

- [Official multiple-monitor guide](https://www.spice-space.org/multiple-monitors.html):
  channel/head arrangements, whole-set monitor requests and transitional layouts.
- [spice-gtk 0.42 widget, commit f04479c](https://gitlab.freedesktop.org/spice/spice-gtk/-/blob/f04479c16f0969fb394ebe74b6eff74e560a42f0/src/spice-widget.c):
  `get_display_id`, crop selection and monitor-local pointer transform.
- [Pinned agent header](https://gitlab.freedesktop.org/spice/spice-protocol/-/blob/499cc8326a672e9e5747efc017319b19e1594b42/spice/vd_agent.h):
  signed positioned monitor configuration and sparse-monitor capability requirements.

C3 functional acceptance was reported by the user before this slice; these C4
changes do not extend that report to multi-monitor behavior.
