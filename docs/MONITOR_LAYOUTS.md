# C4: monitor presentation

## First implementation slice

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

Multi-head/sparse layouts currently scale locally when windows resize. The old
single-monitor guest-resize request is canceled and suppressed for these layouts:
agent monitor configuration replaces the whole desired monitor set, so reusing it
could disable another head. Full positioned/sparse resize negotiation is the next
C4 slice. Arbitrary multi-head nonzero channels and generalized monitor-to-device
mapping remain unsupported. Closing a head window does not disable its guest monitor.

Automated tests cover wire bounds, crop geometry, texture sharing and pixel uploads,
local input/Retina/letterbox mapping, disabled/unsupported layouts, mixed-ID admission,
configuration-before-surface, unplug, surface destruction, close/reoffer and stop.
Live two-head Linux/shared-surface and Windows/separate-channel validation remains
pending. One physical Mac monitor can host several guest-head windows; the guest
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
