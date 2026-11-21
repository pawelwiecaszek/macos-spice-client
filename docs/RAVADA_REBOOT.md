# Phase 6: confirmed Ravada reboot

## Contract

Pinned Ravada 2.4.6 commit `9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9`:

- [`rvd_front:1335`](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/script/rvd_front#L1335)
  checks user.can_reboot for GET `/machine/reboot/{id}.json`.
  `reboot_machine` at line 4606 requires login and returns `{req: requestID}`.
  The client supplies no force query, alternate route or arbitrary action string.
- [`Front.pm:268`](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/lib/Ravada/Front.pm#L268)
  sets machine-info can_reboot using can_shutdown and can_start. Native reboot
  requires explicit true can_reboot from fresh machine metadata, not the ordinary
  catalog's convenience flags or shutdown permission alone.
- [`Request.pm:677`](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/lib/Ravada/Request.pm#L677)
  queues the reboot command. [`Ravada.pm:5711`](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/lib/Ravada.pm#L5711)
  calls domain.reboot and schedules a refresh after the request. Request.info
  exposes the same job ID/status/error/domain fields as shutdown, not a boot ID.
- [`Domain/KVM.pm:1069`](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/lib/Ravada/Domain/KVM.pm#L1069)
  asks libvirt to reboot. The non-force path does not call reset or the separate
  shutdown/start workflow. Domain._post_reboot updates cached state/network data;
  it does not provide proof that guest boot completed. An active VM can remain
  active through a reboot and its SPICE viewer may stay connected.

## Bounded integration plan

Existing shutdown regressions (445 package/195 hosted tests at the accepted
baseline) lock confirmation, fresh authorization, one-send, cancellation and
stopped-state behavior. With a second concrete consumer, extract only that shared
power-action flow. Use a two-case app enum with fixed routes and per-action
permission/warning/outcome messages; keep Connect and its Start behavior intact.
Retain profile/address/browser-store admission, nonvolatile state checks and
generation-bound confirmation. Do not add a generic command API or dependency.

Reboot confirmation warns to save work and that viewers may disconnect. After a
matching successful job, verify active/non-hibernated/idle metadata and refresh
catalog access. Report request completion and running state, not verified guest
boot. Do not require an observable inactive transition, fetch tickets, reopen a
viewer, or automatically retry/reset if guest reboot is unconfirmed. Cancellation
after sending only stops client monitoring.

Preserve shutdown's distinct forced-power-off warning and inactive final-state
requirement. Add reboot-specific route, permission, duplicate/cross-action,
stale-confirmation, failed-job, ambiguous-send, cancellation and final-state tests.
Then run full regressions, warning-clean Release build/signature verification and
an independent review before a separate live test build.

## Acceptance status

The shared two-action flow is implemented. All 446 package tests and 201 hosted
app tests pass, including the existing shutdown regression suite. Reboot tests
cover its independent permission, confirmation/action identity, denied/revoked
access, ambiguous sends, mismatched jobs, inactive final state and cancellation
with late results. The Release build passes with Swift compiler warnings treated
as errors and its signature verifies. Independent review found no outstanding
issues. Offline Help is updated.

The user accepted both requested live checks on build `9012513`: cancelling reboot
confirmation preserved the connected/usable VDI, and explicitly confirming reboot
restarted the guest with working input afterwards. This is user-reported functional
acceptance on the tested Ravada 2.4.6 deployment, not an instrumented boot trace or
validation of every guest/backend/permission role.

A viewer disconnect is not required. The app's result message still reports only
request completion/running state; this live result does not justify claiming guest
boot verification from metadata alone. If a future reboot is uncertain, check the
portal and guest before another request. The final Phase 6 installation/publication
checkpoint is recorded in the [roadmap](DEVELOPMENT_ROADMAP.md).
