# SPICE and Ravada capability audit

Audit date: 2026-11-11. Baseline: accepted Phase 4, `464425d`.
This is an implementation/evidence matrix, not a declaration of full SPICE parity.

**Conclusion:** the client already implements substantial native SPICE functionality,
but it does not take full advantage of the protocol or every Ravada workflow. Missing
drawing commands and A/V timing remain correctness/interoperability work. Cross-channel
ordering now has a locally tested implementation; live acceptance remains pending. Lower-copy video presentation is a later optimization. Ravada fresh-ticket
reconnect and bounded automatic recovery now have local regression coverage; native
power controls and provisioning remain broker integration work.

## Evidence boundaries

- **Code evidence:** a handler, advertised capability or test exists in this repository.
- **Live evidence:** the user confirmed that scenario on the deployed system.
- **Inference:** expected impact derived from code and official protocol semantics.
- **Unknown:** not established by repository tests or the reported live checks.

Do not collapse implemented, advertised, negotiated, server-configured, guest-supported
and live-tested into one “supported” flag. No production server credentials, cookies,
connection files or guest contents were inspected during this audit.

## SPICE coverage

| Area | Code evidence | Current limits / next verification |
| --- | --- | --- |
| Secure transport, proxy, ticket authentication | `Packages/SpiceKit/Sources/SpiceTransport/ChannelLinker.swift`; `SpiceSession.swift` | SPICE ticket auth supported; SASL-only servers are refused. Preserve per-file CA/subject validation and no TLS downgrade. |
| Still images and caches | `SpiceChannels/ImageResolver.swift:38`; `Tests/SpiceChannelsTests/DisplayReplayTests.swift:45` | Raw/QUIC/LZ/GLZ/ZLIB-GLZ/LZ4/JPEG paths and captured replay tests exist. Cache ordering still needs the cross-channel fix below. |
| Drawing commands | `SpiceChannels/DisplayChannel.swift:334` | `drawRop3`, `drawStroke`, `drawText`, `drawComposite` are dropped. Baseline ROP3/stroke/text are rendering-completeness gaps. Composite is not advertised in the current display-capability set; verify newer schema/capability semantics separately. |
| Channel synchronization | `SpiceChannels/ChannelConnection.swift`; `ChannelSynchronization.swift`; `DisplayChannel.swift` | Implemented and tested locally: processed-message barriers, synchronized invalidation, independent display pixmap/GLZ IDs and bounded cancellation/teardown. [Contract and evidence](CHANNEL_SYNCHRONIZATION.md). Live acceptance pending. |
| Video negotiation | `SpiceChannels/DisplayChannel.swift:57`, `:178`; `Tests/SpiceCodecsTests/VideoDecoderTests.swift:113` | Runtime hardware-supported H.264/H.265 plus MJPEG are advertised. VP8/VP9 are deliberately not advertised. Server encoder/profile compatibility still requires representative live streams. |
| Video delivery | `SpiceCodecs/VideoDecoder.swift:59`, `:149`; `SpiceChannels/DisplayChannel.swift:441`; `App/Display/MetalRenderer.swift:121` | Hardware decode copies pixels to CPU surfaces and uploads them to Metal. No zero-copy CVMetalTextureCache path currently. Frame timestamps feed reports, not presentation scheduling. |
| Playback / recording | `SpiceChannels/AudioChannels.swift:17`; `App/Session/AudioController.swift:94`, `:110`, `:131` | Playback latency is advertised but ignored by the app; playback timestamps are discarded. PCM/Opus playback and raw microphone capture exist. Opus microphone encoding is not enabled; record volume/mute integration needs verification. |
| Input / cursor | `SpiceChannels/InputsChannel.swift:18`; `App/Display/RemoteDisplayView.swift` | Absolute/relative pointer, scancodes, modifiers, cursor and motion-ACK paths exist. Basic live input works; verify varied layouts, pointer modes and focus/lock transitions. |
| Agent / clipboard / files | `SpiceChannels/MainChannel.swift:26`; `App/Session/ClipboardController.swift:61`; `SpiceSession.swift:553` | On-demand text/PNG clipboard with active-window restrictions and Mac→guest file sending exist. No guest→Mac file receiving or WebDAV folders. Capability/disconnect/size behavior must remain gated. |
| Resizing / monitors | `SpiceKit/SpiceSession.swift:104`, `:580`; `App/Session/SessionController.swift:412`, `:425`, `:436` | Live resizing works. Up to four display-channel windows exist, but server monitor-layout events are discarded by the app. Multiple heads in one surface are incomplete. |
| USB / ISO / smartcards | `SpiceChannels/USBRedirChannel.swift:282`, `:293`; `App/Session/USBController.swift:120`; `SmartcardController.swift:107` | Implemented real-device, virtual CD-ROM and smartcard/CCID paths. No isochronous transfers, bulk streams or buffered bulk receiving. Actual card/device/boot-image compatibility needs hardware tests. |
| Migration | `SpiceChannels/MainChannel.swift:182`; `ChannelConnection.swift:94` | Migration is rejected with a clean disconnect; seamless migration is not implemented or advertised as a main-channel capability. Broker reconnect is a different operation. |
| Generic ports / WebDAV / GL scanout | `SpiceKit/SpiceSession.swift:566` | Only implemented channel types are opened. Generic ports, folder sharing and local GL scanout are not implemented. These are separate optional features, not implied by file transfer or Metal presentation. |

Short source paths in this table are under `Packages/SpiceKit/Sources/`;
`Tests/…` paths are under `Packages/SpiceKit/`.
Line numbers are audit anchors and can shift as fixes land.

## SPICE work slices

The C identifiers name scopes, not mandatory execution order.
[The development roadmap](DEVELOPMENT_ROADMAP.md) defines the current delivery order,
hard dependencies, acceptance gates and rules for advancing past a blocked slice.

| Priority | Work slice | Acceptance evidence |
| --- | --- | --- |
| C1: rendering correctness | Implement baseline ROP3/stroke/text semantics; establish composite capability/unsupported behavior explicitly. | Small synthetic wire fixtures, golden pixels, bounds/fuzz cases and representative sanitized server captures for each operation. No copied LGPL decoder/rendering code. |
| C2: synchronization correctness | Resolve advertised cache/dictionary ownership and honor cross-channel serial barriers/invalidation. | Cache population/reference/invalidation, GLZ sharing or negotiated isolation, two-channel ordering, missing/closed channels, cancellation and stale completion after replacement; real replay when available. |
| C3: truthful negotiation and media timing | Audit every advertised bit, connect playback minimum latency/actual device delay to multimedia time, and schedule/drop video frames appropriately. | Capability-to-handler matrix; timestamp wrap/reset, audio-route/rate changes, bounded buffers, A/V drift and stream-report validation. Verify newer STREAM_REPORT schema from pinned upstream source first. |
| C4: monitor coverage | Consume monitor layouts and present individual heads from a single surface. | One/two heads on Linux and Windows, head unplug, scaling/Retina and correct pointer/display coordinates. |
| C5: device / agent coverage | Exercise clipboard, file sending, USB/ISO/smartcard and audio on configured guests/hardware. | Positive and unavailable/denied cases, teardown/cancel and device ownership verified. Do not assume hardware support from wire tests. |
| C6: measured efficiency | Deliver VT pixel buffers to Metal with fewer copies while retaining dirty-region/backpressure guarantees. | Baseline CPU/GPU/memory/frame-pacing measurements on the same VM/network, image correctness and sustained-load limits. |
| Separate optional scope | Seamless migration, SASL, generic ports, WebDAV, bidirectional file transfer and broader USB transfer types. | Versioned protocol contracts, explicit product scope and separate security/permission review. No new libraries or entitlements without authorization. |

These are reviewable implementation slices, not completed features. The historical
SPICE specification is useful for baseline rendering, ordering and multimedia time,
but newer capability/stream/composite semantics need pinned protocol/schema evidence.

## Ravada 2.4.6 coverage

Verified source baseline: tag v2.4.6, commit
`9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9`. Deployment confirmation covers Ravada
2.4.6 with LDAP/FreeIPA authentication; it does not establish every server setting or role.

| Server capability | Current client | Evidence / remaining work |
| --- | --- | --- |
| Browser login and per-profile sessions | Implemented and live accepted | `App/Ravada/RavadaPortalModel.swift`, `RavadaPortalStore.swift`. Keep LDAP authentication in Ravada; no direct directory connection. SSO/MFA/password-change variants remain deployment-specific. |
| Authorized ordinary-user catalog | Implemented and live accepted | `RavadaDesktopStore.swift`; upstream `Front.pm:135–237`. Preserve nested clone IDs and server visibility; never substitute the management catalog. Catalog reads can enqueue preview refreshes. |
| Native search, favorites and Connect | Implemented and live accepted | `RavadaDesktopRow.swift`, `RavadaDesktopStore.swift`. Revalidate catalog access, wait for matching successful jobs and ready permitted display metadata, then parse the connection file. |
| Owned stopped-desktop Start | Implemented and live accepted | Typed fixed route in `RavadaBrokerRequest.swift`; upstream `script/rvd_front:1423`, `:4784`. Submit once; no application retry after ambiguous sends. Cancel does not undo server work. |
| Job and display discovery | Implemented with portal fallback | `RavadaJob.swift`, `RavadaMachineInfo.swift`; upstream `script/rvd_front:1105`, `:1735`, `:2510`; `Request.pm:371`. Management-only info must not be a catalog prerequisite; denied metadata offers the portal. |
| Native fresh-ticket reconnect | Manual flow live accepted; bounded automatic recovery implemented locally, live acceptance pending | `RavadaReconnectRequest.swift`, `RavadaSessionOrigin.swift`, `SessionController.swift`: capture original profile/address/login-store epoch, reauthorize an active desktop, fetch a fresh ticket and validate authority synchronously before same-window replacement. No Start/clone. Eight-attempt transport recovery honors General settings, waits for awake/online availability, and retries only transient broker reads; permission, login and intentional server-close failures stop. Existing authenticated portal document required; sign-in/changed context offers portal recovery. Automated availability/cancellation/budget tests pass without interrupting the host network. Signed-out reconnect and actual network/sleep recovery live checks remain pending. |
| Shutdown/reboot/resume/hibernate | Portal only for Ravada | Upstream routes `script/rvd_front:1321–1423`; permission flags `Front.pm:268–292`. Phase 6 must use server permissions, confirmations, job state and no mutation retries. Catalog convenience flags alone are not universal authorization. |
| Clone/provision/restore, volatile desktops and shared access | Portal fallback | Clone route `script/rvd_front:1290` checks clone/public/access policy. Native self-service is later scope; do not infer permission from a visible base or automatically provision. |
| User messages / notifications | Portal only | `script/rvd_front:2540–2552` exposes user messages; read/unread endpoints mutate message state. Later notification support needs privacy-safe content and a verified polling/WebSocket lifecycle. |
| Bookings / schedules | Portal only; configuration-dependent | `Front.pm:146–152` filters catalog by allowed booking; `/booking` and `/v1/bookings/` exist at `script/rvd_front:2895+`. LDAP backing alone does not prove bookings are enabled or a user may manage them. |
| SPICE guest integration / devices | Common client stack, availability varies | Ravada provides VM configuration and connection details; actual channels/codecs require its QEMU/spice-server, VM hardware and guest drivers/agent. Broker API access cannot manufacture USB slots, audio devices or guest-agent capabilities. |

Ravada code-evidence links:
[frontend routes](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/script/rvd_front),
[catalog and action policy](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/lib/Ravada/Front.pm),
[request identity and access](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/lib/Ravada/Request.pm),
[display metadata](https://github.com/UPC/ravada/blob/9e1dd6b5a99e34975aba9c8b8a0d41924b3367b9/lib/Ravada/Front/Domain.pm).

## Deployment validation still needed

- Obtain administrator-supplied versions for QEMU, spice-server, guest-agent and display
  drivers; VM channel/USB-slot/audio/monitor configuration; enabled streaming codecs;
  relevant Ravada user permissions and booking/provisioning policy. No server changes
  are required just to document these. Do not infer them from the Ravada version.
- Validate clipboard text/PNG, Mac→guest file sending, playback/microphone, multiple
  heads, ISO, a suitable USB device and smartcards on representative Linux/Windows
  guests. Record actual negotiated availability and unavailable reasons, not secrets.
- Capture sanitized evidence for unsupported draws, synchronization/cache behavior and
  A/V timing before making performance/completeness claims. There is no reproducible
  CPU/GPU/bandwidth baseline yet.
- Phase 1–4 live acceptance proves the reported login/catalog/start/VDI/input/resize/
  cancellation flows, not blanket protocol, device or media acceptance.

## Official references

- [SPICE overview](https://www.spice-space.org/index.html)
- [SPICE protocol: drawing, channel synchronization, multimedia time and migration](https://www.spice-space.org/spice-protocol.html)
- [SPICE user manual: server/guest prerequisites and optional services](https://www.spice-space.org/spice-user-manual.html)
- [Multiple monitors](https://www.spice-space.org/multiple-monitors.html)
- [Playback buffering and delay reference](https://www.spice-space.org/api/spice-gtk/SpicePlaybackChannel.html)
- [Agent/monitor/clipboard reference](https://www.spice-space.org/api/spice-gtk/SpiceMainChannel.html)
- [USB redirection](https://www.spice-space.org/usbredir.html)
- [Apple VideoToolbox properties](https://developer.apple.com/documentation/videotoolbox/decompression-properties)

GTK API documentation is a behavioral reference, not a dependency or permission to
copy implementation. The client remains native Swift/Metal with no new libraries.
