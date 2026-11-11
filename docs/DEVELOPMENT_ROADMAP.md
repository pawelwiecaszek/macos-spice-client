# Client development order

Updated: 2026-11-11. Execution plan for remaining work; supersedes the original
phase-number order. Phases 1–4 stay accepted. Help is implemented/tested locally at
`09c5cf0`; the installed app is accepted Phase 4. Publication is a separate decision.

## Requirements summary

Deliver reliable Ravada desktops while retaining Proxmox/manual .vv support. Reuse
existing protocol, broker, session and device code. Prefer correctness and concrete
user benefit over feature count. No dependencies, server changes, credential copying,
new entitlements or unrelated cleanup are implied by this plan.

Evidence: [capability audit](CLIENT_CAPABILITIES.md), `App/Ravada/RavadaDesktopStore.swift:128`,
`App/Session/SessionWindowManager.swift:153`, `App/Session/SessionController.swift:201`.
Audit evidence, not marketing claims, determines whether a capability is complete.

## Ordered implementation steps and acceptance gates

The order below is the default delivery priority, not a claim that every row is a
technical prerequisite for every later row. Implement one bounded slice at a time.

| Order | Slice | Why here / reuse | Concrete completion gate |
| --- | --- | --- | --- |
| 0 | Freeze baseline and prepare the next slice | Reuse existing fixtures, acceptance logs and the audit; record unknown backend/guest versions when available. Pin only the protocol/API contract needed next. | Record baseline commit, one target failure/scenario and a failing regression fixture. Inventory offered/implemented capabilities without exposing secrets. Missing server facts block live claims, not offline tests. |
| 1 | **C2: channel/cache ownership and synchronization** | `SpiceChannels/ChannelConnection.swift:90` ignores waits; `SpiceChannels/DisplayChannel.swift:142,175` uses separate resolvers with the same advertised cache/dictionary IDs. Resolve ownership and teardown in the existing paths, not a generic lifecycle framework. | Pin serial/mini-header and cache-ID semantics. Decide explicit sharing or permitted ID isolation. Test cache population → cross-channel reference → synchronized invalidation, GLZ ownership, processed-message barriers, missing/closed channels, cancellation and stale completion after replacement. Keep memory/waits bounded. |
| 2 | **Phase 5: fresh-ticket reconnect**, manual first, then automatic recovery | Reuse `App/Ravada/RavadaDesktopStore.swift:128`, existing typed routes and `App/Session/SessionWindowManager.swift:153`. Deliver independent Ravada value without waiting for all drawing or A/V work. Stabilize authorization/session replacement before machine controls. | Bind original portal origin, login-store epoch and machine identity; reauthorize and fetch a fresh ticket without Start/clone. Replace the same window; preserve preferences and reject stale results. Then test bounded network/sleep/wake recovery, logout, revoked access, deleted/stopped machine and profile edits. Proxmox/manual behavior unchanged. |
| 3 | **C1: missing drawing operations**, split into ROP3 → stroke → text | `SpiceChannels/DisplayChannel.swift:334` drops these operations. Reuse surface/image/brush helpers; do not rebuild the renderer. Keep unadvertised composite separate until its contract/need is verified. | Automated gate per operation: synthetic wire cases, golden pixels, clipping/pixel-format/bounds failures; existing replay stays correct. Live gate: representative sanitized real replay when available, recorded separately. |
| 4 | **C3: capability truth and A/V timing**, split into audio → video | `App/Session/AudioController.swift:94` discards timestamps/latency. Extend existing `SpiceChannels/MultimediaClock.swift`; settle timestamp/frame lifecycle before GPU delivery changes. | Automated gate: affected capabilities map to handlers/tests; consume minimum buffering and actual delay; test wrap/reset/rate/route changes, stop/reconnect cleanup, bounded queues and scheduled/dropped video. Live gate: compare same-guest A/V drift before/after. |
| 5 | **Phase 6: permission-aware actions** | Reuse Phase 4 job handling and Phase 5 authenticated identity/readiness. Extract only a small shared operation helper where the second consumer demonstrates duplication. | Implement one fixed action at a time. Allowed/denied account tests, explicit confirmation for disruptive actions, matching job result, duplicate-click suppression and no automatic mutation retry. Closing a VDI still never shuts it down. |
| 6 | **Phase 8A / C4: true multi-head presentation** | `App/Session/SessionController.swift:412` discards layout events. Settle head/surface geometry and input coordinates before optimizing video-to-Metal layout. | Single-surface two-head and separate-channel guests; correct head crops and pointer mapping, resize/Retina/scaled behavior, unplug/fullscreen and monitor-count/size bounds. |
| 7 | **Phase 7 / C5: sharing and device UX** | Reuse existing `USBController`, `SmartcardController`, `ClipboardController`, `FileTransferController`, `AudioController`; reuse the capability/availability model instead of per-feature guesses. | Test clipboard text/PNG, Mac→guest files, playback/mic, ISO, eligible USB and smartcard paths on available hardware, plus denied/absent/agent-loss/teardown cases. Record unsupported hardware explicitly; do not block unrelated work waiting for a card/device. |
| 8 | **Phase 8B / C6: measured video efficiency** | `SpiceCodecs/VideoDecoder.swift:149` copies pixels; `App/Display/MetalRenderer.swift:121` uploads them. Reuse the settled timing/head/surface interfaces rather than redesigning them during optimization. | Establish same-VM/network CPU/GPU/memory/frame-pacing baseline first. Optimize a demonstrated hot path in one slice; prove correct images, retained clipping/cache/backpressure/memory limits and a measured gain without an A/V or monitor regression. |
| 9 | **Optional 9/10 and separately scoped extensions** | Provisioning, notifications, persistent helper, migration, SASL, WebDAV and broader USB are distinct contracts/risks. Existing portal remains the fallback. | Select a concrete user need and verify deployed support/permissions before implementation. Each feature gets its own scope and acceptance gate; no universal full-parity rewrite. |

Short package source paths above are under `Packages/SpiceKit/Sources/`.
Source anchors are explained in the audit.

## Hard dependencies versus delivery preferences

- **Hard:** a pinned contract and regression fixture before its implementation; correct
  session/permission identity before reconnect/actions; actual Start completion before
  opening a stopped desktop; time/geometry ownership before optimizing that pipeline.
- **Independent:** Phase 5 does not require complete stroke/text, A/V or monitor work.
  Phase 6 also does not technically depend on all drawing/media fixes; these remain
  correctness priorities rather than mandatory gates. Drawing fixtures and hardware
  tests do not all depend on each other. Their default serial priority limits shared-file churn; it is
  not a demand to finish all SPICE parity before delivering any Ravada feature.
- **Reuse:** C2 settles channel/cache identity and teardown; reconnect uses existing
  session replacement. C3 extends the existing multimedia clock and resets it through
  the same lifecycle instead of maintaining a second protocol/media stack (`App/Session/SessionWindowManager.swift:153`).
- **Escape rule:** if C1–C3 is blocked on inaccessible source, a representative capture
  or unavailable hardware, record the exact missing evidence and advance the next
  independent slice—normally Phase 5. Do not repeat open-ended research or invent wire
  behavior. Offline correctness tests remain useful without backend access.
- **Separate gates:** automated implementation completion, local live acceptance and
  publication are distinct. Missing captures/hardware leave live acceptance pending;
  they do not force repeated test runs or hold independent features. Do not relabel
  a fixture-only result as live-verified or install an unaccepted slice by default.

## Efficiency rules

1. One active implementation branch/slice. A second agent is useful for bounded source
   research or independent review; avoid parallel writers in channel/session/renderer code.
2. Use `CLIENT_CAPABILITIES.md` as the evidence ledger; update it as each gap closes.
   Consult the pinned source for the current contract, not the whole protocol again.
3. Start with the smallest failing scenario. Reuse fixtures and helpers. Add abstractions
   only after a real second consumer needs them; do not pre-build a generic broker SDK.
4. Run targeted tests while iterating. At the slice gate, run the required core suite and
   warning-clean app build once; run UI tests/screenshots when that flow changes.
   Repeat checks only after relevant edits/failures, not because time remains.
5. Freeze the tested commit, then do one independent review and targeted corrections.
   Live-test only the changed scenario and material regressions; record automated versus
   live evidence separately. Help content changes with user-visible behavior.
6. Do not optimize CPU copies before measuring them, add WebSockets before proving polling
   inadequate, or rebuild the existing USB/agent features instead of testing them.
7. Local acceptance, installing an app and publishing a PR are separate gates. Do not
   bundle several phases into an older PR, auto-replace a running VDI or depend on an
   unmerged upstream response to continue safe local work.

## Risks and mitigations

- **Scope explosion:** split drawing/media/reconnect into the explicit sub-slices above;
  optional features stay optional. A blocked item does not silently expand its scope.
- **False dependencies:** the priority list is not a single all-or-nothing chain. Use the
  escape rule, and promote a reproduced user-critical bug ahead of convenience features.
- **Contract drift:** verify the exact relevant Ravada 2.4.6/SPICE schema before coding;
  fail to portal/unsupported state instead of weakening permissions or TLS.
- **Rework:** retain one source of authorization, one job observer, one multimedia clock
  and explicit session epochs. Preserve existing public `.vv` parsing and UI separation.
- **Overclaiming:** backend/guest versions, actual negotiated features, hardware coverage
  and performance measurements remain unknown until recorded; passing a launch is not
  acceptance of every SPICE feature.

## Verification and next step

C2 is implemented locally with wire, ordering, cancellation and cache-isolation
regressions; see [the pinned contract and acceptance boundary](CHANNEL_SYNCHRONIZATION.md).
Automated completion and live acceptance are recorded separately. The installed
application remains accepted Phase 4.

**Next:** finish C2 review and live regression checks, then Phase 5 manual fresh-ticket
reconnect using the existing broker and session-replacement paths. Automatic recovery
follows only after the manual flow is verified.
