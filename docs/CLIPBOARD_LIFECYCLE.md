# C5 clipboard lifetime

## Consent and ownership

Clipboard sharing remains opt-in. The native app offers Mac contents and requests
or writes guest contents only for an active session with sharing enabled. Stop,
focus loss and effective session-preference changes revoke queued sharing.
Preference revocation is synchronous, before asynchronous UI cleanup. A response
cannot overwrite a newer local pasteboard change.

Wire-owned agent, negotiation and guest ownership observations travel with each
delivery. A new GRAB or RELEASE retires earlier ownership before the UI consumes
that control, including while PNG conversion is suspended. Polling ownership does
not count as a new local copy or echo the guest's old clipboard back to it.

## Requests and bounded delivery

REQUEST/DATA have no request identifier. `opaque` and GRAB_SERIAL do not correlate
their replies. The client therefore permits one outstanding guest request and holds
only the latest deferred offer. New GRAB, RELEASE, timeout and capability
reannouncement do not prove that an old response has drained. An invalidated,
committed request remains a drain-only record until its matching response or actual
agent replacement. NONE and matching-type empty replies complete without replacing
the Mac clipboard. This quarantine is a conservative local policy.

A local transmission receipt distinguishes a committed request from one provably
never sent. Revoking an unsent request clears that barrier safely. Sharing and peer
state are checked again after encoding, immediately before first-chunk commitment.
Started messages retain valid framing; already committed payloads cannot be recalled.

The inbox is an unfolding stream with 16 events and 32 MiB of queued DATA by default
(finite SDK limits: 64 events/32 MiB). It never silently replaces a control message.
Overflow, malformed controls or consumer termination end clipboard delivery, retire
its observations and leave the VDI connected. Fixed diagnostic categories contain
no clipboard content. Recovery from terminal clipboard failure requires reconnect.
An unanswered committed request expires for writing after five seconds but stays
quarantined; if the peer never responds, reconnect rather than accepting an
unidentifiable late response as fresh data.

Outgoing clipboard actions are limited to 16 queued messages inside the shared
agent byte budget, including worst-case text conversion. Text line endings use
fresh peer capabilities. Failed/oversized conversion produces no-data, never a
truncated image. File, clipboard, monitor and generic agent admission use an
independently owned sender, so cancelling a feature task cannot cancel the shared
socket. Agent replacement still retires queued old-agent work.

## Images and evidence

ImageIO conversion runs off the main actor, with one conversion per controller.
Encoded data is limited to 32 MiB and decoded dimensions to 64 Mi pixels, checked
without multiplying hostile dimensions. Incoming PNG must actually be PNG. The
local TIFF fallback is re-encoded as PNG; conversion completion rechecks consent,
ownership and pasteboard freshness before writing.

Regression tests use unique named pasteboards, not the user's general clipboard.
Coverage includes text/PNG/TIFF, no-data replies, overlapping ownership, stale image
completion, preference/focus/stop, agent replacement, request receipts, byte/event
pressure, exact control layouts and cancellation-aware socket probes. The user
reported all requested live checks passed on build `66098b3`: text and image copying
in both directions, preservation of newly copied Mac text while the VDI was in the
background, and text copying after reconnect. This accepts the clipboard slice on
the tested deployment; other guest/agent combinations remain unverified.

Protocol references: [agent protocol](https://www.spice-space.org/agent-protocol.html),
[pinned agent header](https://gitlab.freedesktop.org/spice/spice-protocol/-/blob/499cc8326a672e9e5747efc017319b19e1594b42/spice/vd_agent.h),
[spice-gtk 0.42 behavior](https://gitlab.freedesktop.org/spice/spice-gtk/-/blob/f04479c16f0969fb394ebe74b6eff74e560a42f0/src/channel-main.c).
These were consulted for semantics; no upstream implementation was copied.
