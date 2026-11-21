# Phase 6: Hibernate and saved-state Resume

## Verified scope and contract

Pinned Ravada 2.4.6 commit `9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9`:

- [`rvd_front:1410`](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/script/rvd_front#L1410)
  exposes GET `/machine/hibernate/{id}.json`, gated by admin or can_shutdown.
  `hybernate_machine` at 4916 queues `Request.hybernate(id_domain, uid)` and returns
  `{req: requestID}`. Domain._allow_hibernate at 837 separately enforces the actual
  hibernate grant in the backend. Front._init_available_actions advertises
  can_hibernate using can_shutdown and nonvolatile state; it is a preflight hint,
  not proof that the backend grant will permit completion.
- [`Domain/KVM.pm:1219`](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/lib/Ravada/Domain/KVM.pm#L1219)
  uses managed_save. is_hibernated at 1145 checks the managed saved image.
  This first native slice requires fresh metadata type `KVM`; unknown/other
  backends stay in the portal rather than assuming their save semantics.
- `/machine/resume/{id}.json` and KVM.resume at 1132 unpause a paused VM; they do
  **not** restore managed hibernation. Saved-state Resume must use the verified
  `/machine/start/{id}.json` route (rvd_front:4784), after explicit can_start,
  inactive and hibernated checks. No paused-VM Resume route is added to the client.
- [`Domain/KVM.pm:882–925`](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/lib/Ravada/Domain/KVM.pm#L882)
  starts with libvirt create, which normally restores a managed saved image.
  On certain restore failures Ravada removes the saved image and starts fresh.
  The exposed route has no verified preserve-image-only option. Confirmation and
  Help must warn about this behavior; a running VM does not prove memory restored.
- Machine-info supplies can_start, can_hibernate, is_active, is_hibernated,
  is_volatile and type through Domain.info and Front._init_available_actions.
  Ordinary catalog clone rows do not distinguish stopped from hibernated; their
  can_hibernate flag is just active/nonvolatile. Metadata, not catalog flags,
  decides admission. The backend still authorizes the actual action.

## Bounded integration plan

Extend the existing two-action flow with two explicit cases. Hibernate requires a
running, non-hibernated KVM machine; Resume requires an inactive, hibernated KVM
machine. Both require known nonvolatile state, no pending work and their own fresh
metadata flag before and after confirmation. Keep profile/address/login-store
admission and one application-level send with no automatic retry.

Hibernate completion requires matching successful job and inactive+hibernated
metadata. Resume completion requires matching successful Start job and active+
non-hibernated metadata; report running, not verified restored guest memory.
Neither action fetches a ticket or opens a viewer. Connect and VDI Reconnect must
never silently resume a known hibernated machine. Offer explicit Resume guidance.
Keep Shutdown/Reboot state gates, warnings and tests unchanged.

Label inactive catalog rows "Not running", since their hibernation state is not
provided. Enable Resume discovery only for known inactive rows; preflight rejects
ordinary stopped or unsupported machines without issuing Start. Add fake-server
tests for permission/state/backend checks, cold-start prevention, stale/cross-action
confirmations, cancellation, ambiguous jobs and final-state distinctions.

## Acceptance status

Implementation is complete locally. All 448 package tests and 207 hosted app tests
pass. New simulated tests cover Hibernate→explicit Resume, no implicit Connect
start, backend/flag/state revocation, cold-start prevention, wrong hibernation
results, backend grant failure, unknown saved-image-removal progress, cancellation
and stale confirmations. Shutdown/Reboot regressions still pass. The Release build
passes with Swift warnings treated as errors and its signature verifies.
Independent review found no outstanding issues. Offline Help is updated.

The user accepted all requested live steps on build `6871dea`: Hibernate Cancel
preserved the VDI; confirmed Hibernate ended it and reported hibernated state;
Resume Cancel left the desktop not running; explicit Resume followed by viewer
Reconnect preserved the disposable unsaved marker and working input. This accepts
the tested Ravada 2.4.6 KVM deployment. The observation is user-reported, not an
instrumented memory-integrity trace or validation of other roles/backends.

The cold-start fallback was not exercised, and its confirmation/Help warning stays
in place. Neither a successful job nor running metadata proves memory restored on
future attempts. Shutdown/Reboot acceptance remains recorded separately. The final
Phase 6 release checkpoint follows in the development roadmap.
