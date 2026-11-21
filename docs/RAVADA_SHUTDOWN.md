# Phase 6: confirmed Ravada shutdown

First scope: My Desktops → Actions → Shut Down for an authorized running,
nonvolatile machine. [Reboot follows as a separate local slice](RAVADA_REBOOT.md).
Force shutdown, resume/hibernate and VDI-toolbar power controls remain portal-only.
Closing a VDI never submits a power action.

## Pinned server contract

Ravada 2.4.6, commit `9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9`:

- [`script/rvd_front:1321`](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/script/rvd_front#L1321)
  checks user.can_shutdown before `/machine/shutdown/{id}.json`. The handler at
  line 4587 requires login and returns `{req: requestID}`. This is a mutating GET,
  with no request body. The native route never accepts a force query or arbitrary
  action name. Session cookies remain in WebKit's isolated client world.
- [`Domain.pm:2353–2432`](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/lib/Ravada/Domain.pm#L2353)
  returns machine-info including is_volatile and calls
  [`Front.pm:268`](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/lib/Ravada/Front.pm#L268)
  to populate can_shutdown from the authenticated user's actual permission.
  `/machine/info/{id}.json` itself requires can_manage_machine (rvd_front:1105).
  Denied metadata falls back to the portal. The ordinary clone catalog's
  can_shutdown merely reflects is_active (Front.pm:222), so it cannot authorize
  this operation.
- [`Request.pm:371`](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/lib/Ravada/Request.pm#L371)
  limits job-info to authorized users and exposes id/status/error/id_domain. It
  does not expose command; the client validates the returned receipt's job ID,
  successful terminal status and matching machine ID without inventing that field.
- [`Domain.pm:3436`](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/lib/Ravada/Domain.pm#L3436)
  uses the configured shutdown timeout (default 120 seconds) and can schedule a
  later force shutdown if the machine remains active. The UI therefore says
  **Shut Down**, warns about forced power-off and never promises graceful-only
  behavior. Volatile machines can be removed by server policy; this first slice
  rejects volatile or unknown volatility instead of invoking that workflow.

## Client admission and completion

Preparation refreshes ordinary catalog access and waits for idle machine metadata.
Only true metadata permission, active/non-base/non-hibernated state and known false
volatility offer confirmation. The dialog identifies desktop, machine ID and saved
portal, warns to save work and describes server timeout behavior.

After confirmation, repeat authorization/state checks and reject a changed display
name before sending once. Every request retains the existing MainWindowController
guards for the original saved profile ID, exact address and browser-store epoch,
before and after transport. No action is added to a VDI window; session-origin
power control remains separate scope.

Wait for the matching successful job, then separately verify an inactive,
non-hibernated machine with no pending work and refresh the authorized rows. A
done job alone does not report shutdown. Client monitoring is bounded to 180 polls
per phase and a shared 180-second deadline after confirmation; preparation is
bounded to 90 seconds. A longer server timeout may outlast monitoring.

Duplicate clicks and concurrent Connect/refresh/action admission are blocked.
Navigation, hide, minimize, close and explicit Cancel retire confirmation/work.
Cancellation after submission stops client monitoring only. Ambiguous sends,
malformed receipts, failed/mismatched jobs and unconfirmed final state never cause
an automatic power-action retry; the UI directs the user to check the portal.

## Verification status

All 445 package tests and 195 hosted app tests pass. Coverage includes fixed
non-force routes, unknown/denied/revoked metadata permission, volatile state,
confirmation cancellation and stale tokens, duplicate admission, receipt/job
identity, an unstopped guest, late callbacks and shutdown-specific transport
ambiguity. App-wide hide/unhide tests share one serialized suite to avoid broadcast
notification interference. The Release build passes with Swift compiler warnings
treated as errors and its signature verifies. Independent review found no
outstanding issues.

The user accepted the live sequence on build `a74a32f`: cancelling confirmation
left the existing VDI connected and usable; explicitly confirming shutdown ended
the viewer session and displayed the stopped-state confirmation; My Desktops →
Connect then started/reopened the desktop and input worked. This accepts the
tested Ravada 2.4.6 deployment. It does not establish live denied-account behavior,
volatile-machine handling, timeout/forced-power-off behavior or broader roles and
server versions; those negative branches have simulated coverage.

The final Phase 6 installation/publication checkpoint is recorded in the
[roadmap](DEVELOPMENT_ROADMAP.md). Server mutation always requires the user's
explicit in-app confirmation on a desktop with saved work.

Live acceptance sequence: cancel the first shutdown confirmation and verify the
VDI remains usable; then explicitly confirm shutdown of a disposable/saved desktop,
wait for stopped-state confirmation and the viewer disconnect, and explicitly
Connect again to start/reopen it. If permissions or metadata are unavailable, record
the portal fallback rather than bypassing it. Do not repeat an uncertain submission.
