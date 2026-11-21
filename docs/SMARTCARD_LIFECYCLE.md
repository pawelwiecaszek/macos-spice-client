# C5 smartcard lifetime

Physical smartcard acceptance is unavailable: the user has no smartcard to test.
Automated fake-card tests can establish ownership and cleanup behavior, but cannot
establish CryptoTokenKit, reader firmware, card applet or guest-driver compatibility.

## Scope

The native SPICE smartcard channel and the USB CCID fallback must release exclusive
Mac card access on removal, channel failure and session shutdown. Pending reader
registration, card acquisition and APDU work must not resurrect a retired share.
Attachment identity must remain valid across cleanup, including when a USB slot is
reused by a different device or ISO.

Availability distinguishes connection policy, missing server transport/capacity,
unavailable Mac smartcard access, no reader and a reader with no card. These are
ordinary unavailable states; none should initiate card acquisition.

## Implemented behavior

Native channel and USB shares carry insertion UUIDs. Delayed removal and events
cannot affect a replacement share. The app reserves sharing through pending
admission and release, revokes pending operations on stop/unshare/card loss, and
does not cancel a task midway through a socket write. Policy-disabled, absent-card
and unavailable-host cases never create a card backend.

Reader waits have bounded, nonce-owned timeouts. Closing a channel wakes reader
waits and revokes a pending acquisition without waiting indefinitely on a hardware
callback. Late successful acquisition releases itself. Failed or ambiguous wire
writes close the optional smartcard channel; they are not retried. Cleanup remains
reserved until disconnect finishes, and old APDU completions cannot reply for a
replacement insertion.

The CCID reader rejects work after close, serializes command processing, discards
responses invalidated by reset/close and releases late power-on results. Mac card
acquisition and transmission have matching ownership checks; concurrent disconnects
join one exclusive-session release.

## Verification and limits

All 443 package tests and 185 hosted app tests pass with Swift compiler warnings
treated as errors. Simulated regressions include held reader/connect/ATR/APDU/
disconnect operations, stale removal, empty ATR, reset during CCID power-on,
pending stop/unshare, no-reader/card/access/policy admission and USB identity.
Review has no outstanding findings. The separate Release build verifies with
executable SHA-256
`fb9951a15bea03c6f3159b55f7603e8bde8248fc3a8fb70476056c2cf791161c`.

Physical card compatibility and a live check of this build's no-reader menu remain
unverified. No physical-card success is claimed. Sharing a security key's smartcard
function does not imply sharing its OTP or FIDO functions. The existing channel and
CCID paths remain the only supported transports; no new dependency or entitlement
was added. The accepted USB/ISO build and installed C4 application are unchanged.
