# C5 first slice: file-transfer lifetime

## Problem and behavior

Previously, cancelling a transfer while waiting for the guest's initial readiness
or final result left its continuation suspended. A late worker or progress callback
could also clear the UI state of a replacement transfer.

Both status waits are now cancellable and bounded (30 seconds by default; the SDK
parameter is clamped to 1 ms–120 seconds). Expiry reports an ambiguous timeout and
does not retry START. Agent loss, transfer-disabled policy and session teardown wake
waiting transfers. Unknown/completed IDs and duplicate readiness/terminal results
are ignored. Active IDs are never reused within a session. At most 16 transfers and
two early results per active ID are retained.

Files use an independent, main-channel-owned sender. A cancelled caller never writes
protocol cleanup directly to the shared network connection: that transport cancels
its connection when a cancelled task writes. START, DATA and CANCEL instead bind to
the wire-owned agent epoch. Admission and queued delivery reject replaced agents;
fresh guest-disabled policy blocks unsent START/DATA while allowing cleanup.

The file queue holds at most 64 ordinary messages, with reserved cancellation
capacity up to 80 total and the existing shared byte budget. Unsent messages for a
cancelled ID are removed. A message already started finishes its framing before
cleanup; already transmitted bytes cannot be recalled. Transfers are paced by the
combined queued-byte count. No per-packet tasks or background service are added.

The app keeps one generation-bound worker and one newest-only progress consumer.
Per-file identities reject progress from an earlier file, including within the same
worker. Cancel releases queued security scopes immediately; each active sender
releases its own scope when it exits. Only successfully acquired scopes are released.
The local queue accepts 256 waiting files plus the active file. File growth after
START cannot send beyond the originally announced size.

## Verification and acceptance

In-memory session/agent tests cover initial/final cancellation, connection usability
after cancellation with a cancellation-aware transport, timeout without START retry,
agent loss, early back-to-back results, duplicate/unknown/late statuses, active limits
and file growth. Main-channel tests exercise epoch retirement, token starvation,
queue limits/reserved cancellation and fresh guest-disabled policy. Hosted tests
cover replacement workers, late completion/errors/progress, resource release and
queue limits.

Live acceptance remains pending: send a small text file and an image, confirm their
contents in the guest, cancel an in-progress larger file, then send another file and
confirm the VDI stays connected and the progress UI belongs to the new transfer.
Check the guest download folder before repeating an ambiguous/cancelled transfer;
partial files are guest-agent behavior. This slice does not add guest-to-Mac file
receiving or WebDAV folders.

Clipboard text/PNG lifecycle, device availability/denial UX, USB/ISO and smartcard
hardware coverage remain independent C5 work. Previously accepted C3 audio and C4
monitor checks do not establish those device capabilities.
