# C5 USB and ISO lifetime

USB redirection requires a server-provided slot. An ISO occupies one slot as a
read-only emulated CD/DVD drive; it does not modify the VM's configured disks.
Connection-file policy and guest filters still apply to emulated devices.

## Ownership

Each native attachment owns a UUID and a lease for its specific channel. Delayed
detach, guest-eject and shutdown work must release that attachment only, even if
the same slot or image URL is reused. The legacy slot-number API remains available
to SDK clients; the native app uses attachment leases.

Slot cleanup retains its reservation until device abort/close has completed.
Attach checks ownership after wire sends and fails if the channel closed or the
attachment ended meanwhile. A partially transmitted attachment closes that USB
channel rather than retrying an ambiguous handshake. Other SPICE channels remain
independent.

The native controller reserves pending capacity before opening a host device or
image, refuses duplicate operations, and prevents retired completions from
publishing into its UI. Normal feature cleanup does not cancel a task in the middle
of a socket write. A late successful attachment is released through its lease.
ISO file handles close explicitly, and successful security-scoped access remains
held until attachment cleanup completes.

## Acceptance

Automated lifecycle coverage passes for channel-close/attach overlap, cleanup
reservations and joining, stale attachment ownership, failed disconnects,
cancellation-aware transfer replies, reused packet IDs, explicit ISO closure, native pending-operation
shutdown and unavailable-device policy. The full package suite passes (431 tests),
as do all 178 hosted app tests, including eight controller lifecycle tests.
The Release build passes with Swift warnings treated as errors and its signature
verifies. Review has no outstanding findings. The user accepted ISO mount/read/
eject/remount and explicitly confirmed physical USB attach/release, including Mac
access after release, on the separate Release build with executable SHA-256
`a3da352e74fb100ca44396368883966fd4a6d9fe65d149a2f1513f207a5543fd`.
This accepts the slice on the tested deployment, not every device/guest combination.

The acceptance checklist is:

- With no USB slots, show an explanation and disable attachment actions.
- With a free slot, mount a disposable ISO, read a known file in the guest, then
  eject and mount it again. Confirm the VDI remains usable.
- Close a session while an attachment is pending; confirm no late device/UI state
  survives. Reconnect and verify the slot can be used again.
- If an eligible spare USB device is available, redirect and release it, checking
  that macOS regains access. Never use the only keyboard or mouse for this test.

Absent USB slots and pending-attach shutdown have automated coverage; separate live
acceptance of those branches was not established. Other absent USB hardware or
server configurations are recorded as unavailable coverage. Passing wire tests
does not imply hardware compatibility. Smartcard coverage is a separate slice;
isochronous transfers, bulk streams and buffered bulk receiving remain unsupported.
