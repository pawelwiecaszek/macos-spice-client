# AGENTS.md — Spice macOS Client

Guidance for coding agents (Claude Code and others) working in this repository.
Read this file fully before making changes. If something here conflicts with a direct
instruction from the maintainer, the maintainer wins — then update this file.

---

## 1. Mission

Build a **native macOS SPICE remote-display client** that:

1. Targets **macOS 26 (Tahoe) and later only**. No back-deployment, no `#available` checks for anything below 26.
2. Renders the remote desktop with **Metal** (no OpenGL, no GTK, no X11, no Electron).
3. Implements the **SPICE protocol natively in Swift**, and opens **virt-viewer `.vv` connection files** as its primary entry point (Proxmox VE, oVirt/RHV, plain QEMU/libvirt).

Typical user flow: user clicks "SPICE" in the Proxmox web UI → browser downloads `pve-spice.vv` → macOS opens it with this app → session connects within a second (Proxmox tickets expire in ~30 s).

### Non-goals (unless the maintainer asks)

- Wrapping `spice-gtk` / GStreamer / GLib (heavy, LGPL, non-native). Reading their source as a **protocol reference** is fine — see §9 Licensing.
- iOS/iPadOS/visionOS targets (keep `SpiceKit` platform-agnostic so this stays possible later).
- WebDAV (folder sharing), port channels in v1 — design for them, don't build them. (USB redirection, ISO mounting and smartcard passthrough **are** in scope — see §7a, §7b and §7c.)
- VNC/RDP.

---

## 2. Tech stack (fixed decisions)

| Area | Choice |
|---|---|
| Language | Swift 6.2+, **Swift 6 language mode, strict concurrency = complete** |
| Toolchain | Xcode 26+ |
| UI | SwiftUI app lifecycle; AppKit (`NSView`) for the remote display surface and input capture |
| Rendering | Metal via `CAMetalLayer` in a custom `NSView` (or `MTKView` if it stays simple). Shaders in `.metal` files. |
| Video decode | VideoToolbox (H.264, H.265; VP9 via `VTRegisterSupplementalVideoDecoderIfAvailable`) → `CVPixelBuffer` → `CVMetalTextureCache` (zero-copy) |
| Still images | Native Swift decoders for QUIC / LZ / GLZ / LZ4 / ZLIB-GLZ; ImageIO for JPEG |
| Networking | `Network.framework` (`NWConnection`), TLS via `sec_protocol_options` |
| Crypto | Security.framework (`SecKeyCreateEncryptedData`, `.rsaEncryptionOAEPSHA1`) for SPICE ticket auth |
| Audio | AVAudioEngine (playback + record); Opus via a vetted Swift/C package or raw PCM fallback |
| Logging | `os.Logger` with subsystem `com.<org>.spiceclient`, one category per channel |
| Tests | Swift Testing (`import Testing`) for new tests; XCTest only for UI tests |
| Dependencies | Swift Package Manager only. **Ask before adding any dependency.** No CocoaPods/Carthage. |

Architecture: **Apple silicon (arm64)** is the primary target. Don't add Intel-specific code paths. Metal 4 (`MTL4*`) APIs are allowed only behind a capability check with a classic-Metal fallback; default to classic Metal.

---

## 3. Repository layout

```
.
├── AGENTS.md                 ← this file
├── CLAUDE.md                 ← "@AGENTS.md" import for Claude Code
├── SpiceClient.xcodeproj     ← app target only; thin
├── App/                      ← SwiftUI app, windows, menus, settings, document handling
│   ├── SpiceClientApp.swift
│   ├── Session/              ← SessionController (glues SpiceKit ↔ UI)
│   ├── Display/              ← RemoteDisplayView (NSView), MetalRenderer, Shaders.metal
│   ├── Input/                ← keyboard/mouse capture, keymaps
│   ├── Audio/
│   ├── Resources/            ← Info.plist, entitlements, Assets
│   └── Tests/                ← UI tests
└── Packages/
    └── SpiceKit/             ← Swift package, NO AppKit/SwiftUI imports
        ├── Sources/
        │   ├── VVFile/       ← .vv parser → ConnectionProfile
        │   ├── SpiceWire/    ← headers, enums, message codecs (pure, no I/O)
        │   ├── SpiceTransport/ ← NWConnection, TLS, HTTP CONNECT proxy, link + auth
        │   ├── SpiceChannels/  ← Main, Display, Inputs, Cursor, Playback, Record actors
        │   ├── SpiceAgent/   ← vdagent protocol (clipboard, monitors config)
        │   ├── SpiceCodecs/  ← QUIC, LZ, GLZ, LZ4, ZLIB-GLZ, pixel-format converters
        │   ├── USBRedirWire/ ← usbredir protocol codecs + filter rules (pure, no I/O)
        │   ├── USBHost/      ← IOKit/IOUSBHost backend: enumerate, hotplug, capture, transfers (macOS-only)
        │   ├── USBEmulation/ ← emulated USB devices: Mass-Storage BOT + SCSI MMC CD-ROM (ISO mount)
        │   └── SpiceKit/     ← public façade: SpiceSession, delegates/AsyncStreams
        └── Tests/
            ├── Fixtures/     ← .vv samples, captured message blobs, golden images
            └── …Tests/
```

Rules:
- `SpiceKit` must build and test with `swift test` on macOS **without** Xcode project involvement.
- `SpiceWire` and `SpiceCodecs` are **pure**: bytes in → values out. No sockets, no actors, no `Date()`. This makes them fuzzable and trivially testable.
- Metal code lives only in `App/Display`. `SpiceKit` hands the renderer **surface updates** (see §6), never Metal objects.

---

## 4. Build, run, test

```bash
# Core library
cd Packages/SpiceKit && swift build && swift test

# App
xcodebuild -project SpiceClient.xcodeproj -scheme SpiceClient \
  -destination 'platform=macOS,arch=arm64' -configuration Debug build

# All tests
xcodebuild -project SpiceClient.xcodeproj -scheme SpiceClient \
  -destination 'platform=macOS,arch=arm64' test

# Open a .vv file with a debug build
open -a "$(xcodebuild -scheme SpiceClient -showBuildSettings | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/SpiceClient.app" Fixtures/sample.vv
```

Before declaring any task done:
1. `swift test` in `Packages/SpiceKit` passes.
2. App builds with **zero warnings** (treat Swift concurrency warnings as errors).
3. New parsing/codec code has tests with fixtures.
4. No secrets (passwords, tickets, CA keys from real hosts) in fixtures or logs.

---

## 5. `.vv` file support (virt-viewer connection files)

### Format
INI-style, UTF-8, one section `[virt-viewer]` (others like `[ovirt]` may appear — parse and ignore unknown sections). Keys are case-sensitive. Values are unquoted; multi-line values (notably `ca`) have newlines **escaped as `\n`**.

Example (Proxmox-style):
```ini
[virt-viewer]
type=spice
host=pvespiceproxy:6527b3e1:101:pve1::abc123...
host-subject=OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1.example.com
tls-port=61000
password=0123456789abcdef...
proxy=http://pve1.example.com:3128
ca=-----BEGIN CERTIFICATE-----\nMIIF...\n-----END CERTIFICATE-----\n
delete-this-file=1
title=VM 101 - win11
toggle-fullscreen=Shift+F11
release-cursor=Ctrl+Alt+R
secure-attention=Ctrl+Alt+Ins
```

### Keys to support (v1)
| Key | Handling |
|---|---|
| `type` | Must be `spice`; otherwise show a clear "unsupported protocol" error. |
| `host`, `port`, `tls-port` | Plain and/or TLS. If both present, prefer TLS per `secure-channels`; plain port is fallback only for channels not listed as secure. Note: with Proxmox `host` is an opaque proxy target string, not a DNS name — pass it verbatim in the CONNECT request. |
| `password` | One-time ticket. Keep only in memory; zero/clear after auth. **Never log.** |
| `proxy` | `http://host:port` → open HTTP `CONNECT host:port` tunnel per channel, then TLS inside the tunnel. |
| `ca` | Unescape `\n`, parse PEM (one or more certs), use as **sole** trust anchors for this session. |
| `host-subject` | Verify server cert subject matches (compare RDNs order-insensitively, whitespace-trimmed). If absent, verify hostname normally. |
| `secure-channels` | `;`-separated channel names (`main;display;inputs;cursor;playback;record;smartcard;usbredir`, or `all`) that must use TLS. |
| `title` | Window title. |
| `fullscreen` | Start fullscreen if `1`. |
| `delete-this-file` | If `1`, delete the file after reading (only if we have write access via the security-scoped URL; failure is non-fatal, log at `.debug`). |
| `toggle-fullscreen`, `release-cursor`, `secure-attention` | Parse hotkey strings (`Ctrl+Alt+R`, `Shift+F11`) into a `Hotkey` model; map to macOS modifiers. |
| `enable-usbredir` | If `0`, hide all USB/ISO UI for this session. Default: enabled when the server offers usbredir channels. |
| `enable-usb-autoshare` | If `1`, automatically redirect newly plugged devices that pass `usb-filter` (never HID keyboards/mice, see §7a). |
| `usb-filter` | usbredir filter string (rules separated by `\|`, each `class,vendor,product,version,allow`, `-1` = wildcard, hex or decimal). Applied to both manual and auto redirection. |
| `color-depth`, `disable-effects`, `enable-smartcard`, `versions`, `newer-version-url` | Parse and keep in `ConnectionProfile`; may be ignored in v1 but must not cause errors. |

Parser requirements: tolerant of CRLF, BOM, comments (`#`, `;`), blank lines, duplicate keys (last wins), unknown keys. Return a typed `ConnectionProfile` plus a list of warnings. Fuzz-test it.

### macOS integration
- Declare an imported UTI for `.vv` (MIME `application/x-virt-viewer`) in `Info.plist` with `LSHandlerRank = Default`, so double-click and browser "Open" launch the app.
- Use SwiftUI `WindowGroup(for:)` / `onOpenURL` + `NSApplicationDelegate.application(_:open:)` — **connect immediately on open**; don't show an intermediate confirmation dialog (ticket expiry).
- One window per session. Multiple simultaneous sessions must work.

---

## 6. SPICE protocol implementation notes

Primary references (consult, don't guess):
- `spice-protocol` headers: `spice/protocol.h`, `spice/enums.h`, `spice/vd_agent.h` (wire constants, caps, struct layouts).
- `spice-common/common/spice.proto` (message definitions, the canonical schema).
- SPICE protocol spec (`spice-protocol` docs / spice-space.org).
- `spice-gtk` and `spice-html5` as behavioural references.

All multi-byte integers on the wire are **little-endian**. Structs are packed. Write explicit `ByteReader`/`ByteWriter` helpers; never `memcpy` into Swift structs.

### Connection & link
1. Open TCP (optionally via HTTP CONNECT proxy, optionally TLS) per channel.
2. Send `SpiceLinkHeader` (`magic = "REDQ"`, major 2, minor 2, size) + `SpiceLinkMess` (`connection_id`, `channel_type`, `channel_id`, common caps, channel caps).
3. Read `SpiceLinkReply`: error code, 162-byte RSA-1024 public key (SubjectPublicKeyInfo DER), server caps.
4. If server advertises `SPICE_COMMON_CAP_PROTOCOL_AUTH_SELECTION`, send `uint32` auth mechanism (`SPICE_COMMON_CAP_AUTH_SPICE`). SASL is out of scope for v1.
5. Encrypt `password + NUL` with RSA-OAEP(SHA-1) → 128 bytes, send.
6. Read `uint32` link result; map non-zero to typed errors (`permissionDenied` → "ticket expired or invalid" with a hint to re-download the .vv).
7. Always advertise and use `SPICE_COMMON_CAP_MINI_HEADER` (6-byte header: `uint16 type`, `uint32 size`).

Main channel first (`connection_id = 0`). Take `session_id` from `SPICE_MSG_MAIN_INIT` and use it as `connection_id` for every other channel. Open other channels from `SPICE_MSG_MAIN_CHANNELS_LIST`, only for types we implement.

### Channel model
- One **actor per channel**, owning its `NWConnection`, read loop, and ack state.
- Handle generically in a shared base: `SET_ACK` (reply `ACK_SYNC`, then send `ACK` every `window` messages), `PING` → `PONG`, `NOTIFY`, `DISCONNECTING`, `MIGRATE*` (log + disconnect cleanly in v1), `WAIT_FOR_CHANNELS`.
- Expose events to the app via `AsyncStream`s; UI code consumes on `@MainActor`.
- Reconnect policy: none automatic for auth failures; one retry for transient network errors on non-main channels.

### Channels in scope
| Channel | v1 scope |
|---|---|
| **Main** | init, channels list, mouse mode (prefer **client** mode when agent is connected), agent tokens/data/connected/disconnected, name/uuid. |
| **Display** | surfaces (create/destroy, primary surface), `DRAW_FILL`, `DRAW_COPY`, `DRAW_BLEND`, `COPY_BITS`, `DRAW_ALPHA_BLEND`, `DRAW_TRANSPARENT`, invalidate, `MARK`/`RESET`, streams (create/data/clip/destroy, `STREAM_REPORT`), `MONITORS_CONFIG`, GL-draw messages ignored. Advertise codecs only for what VideoToolbox can decode on this machine. |
| **Inputs** | key down/up (PC AT set-1 scancodes), modifiers sync, mouse motion (server mode) / position (client mode), buttons, wheel (buttons 4/5 + horizontal 6/7), motion ack throttling (`SPICE_INPUT_MOTION_ACK_BUNCH`). |
| **Cursor** | set/move/hide/trail, cursor cache; render as `NSCursor` in client mouse mode, as Metal overlay in server mode. |
| **Playback** | PCM S16LE + Opus; latency-aware buffering with AVAudioEngine. |
| **Record** | Microphone (requires `NSMicrophoneUsageDescription`, off by default, user toggle). |
| **USB redir** (`SPICE_CHANNEL_USBREDIR`, spicevmc) | One channel instance per redirectable slot; carries the usbredir protocol. Used for both real devices (§7a) and the emulated CD-ROM (§7b). Advertise `SPICE_SPICEVMC_CAP_DATA_COMPRESS_LZ4` and handle compressed data messages. |

### Image codecs (`SpiceCodecs`)
Implement and test independently with golden fixtures: **QUIC**, **LZ** (RGB16/24/32/RGBA, palettes), **GLZ** (cross-image dictionary keyed by window/id — bound memory, evict per server `GLZ_DICTIONARY` size), **LZ4**, **ZLIB_GLZ**, **JPEG / JPEG_ALPHA** (ImageIO), raw bitmaps (all `SPICE_BITMAP_FMT_*`, top-down vs bottom-up). Output is always premultiplied **BGRA8** in a reusable buffer. Use `Span`/`UnsafeRawBufferPointer` in hot loops; benchmark before micro-optimizing.

### vdagent (`SpiceAgent`)
Over main-channel `AGENT_DATA` with token flow control. Implement: announce capabilities, **clipboard** (text and PNG both directions, via `NSPasteboard`; grab/request/release semantics), **monitors config** (send on window resize, debounced ~300 ms, in pixels not points), mouse in client mode. File transfer is v2.

---

## 7. Rendering (Metal)

- `SpiceKit` owns a CPU-side model of surfaces; it emits `SurfaceUpdate { surfaceID, dirtyRect, pixels | pixelBuffer }`.
- The renderer keeps one `MTLTexture` (`.bgra8Unorm`, `.shaderRead`, storage `.shared` on Apple silicon) per SPICE surface. Apply updates with `replace(region:)` for small rects, or a staging `MTLBuffer` + blit encoder for large/many rects. Video stream frames come in as `CVPixelBuffer` → `CVMetalTextureCache` and are composited into the surface texture with a YUV→RGB shader (BT.601/709 per stream metadata).
- Present: draw the primary surface into the `CAMetalLayer` drawable with aspect-fit scaling, sampling linear when scaled and nearest at 1:1. Honor `backingScaleFactor`; offer "Retina/HiDPI" (resize guest to pixel size) vs "scaled" in settings.
- Drive frames with the view's `displayLink` (macOS 14+ API) and **render only when dirty**. Set `maximumDrawableCount = 3`, `presentsWithTransaction = false`, `displaySyncEnabled = true`.
- Server-mode cursor: separate small texture composited in the same pass.
- Color: tag the layer with sRGB (`CGColorSpace.sRGB`); no EDR in v1.
- Use Metal debug layer and GPU validation in Debug scheme. Name all Metal objects (`label`) for capture debugging.
- Never block the main thread on GPU completion. Never decode images on the main thread.

---

## 7a. USB redirection (real devices)

Goal: plug a USB device into the Mac and use it in the guest, like spice-gtk's "USB device selection".

**Transport.** Each SPICE `usbredir` channel (`SPICE_CHANNEL_USBREDIR`, a spicevmc channel) is one redirection *slot*; the server lists one per `usb-redir` device of the VM (Proxmox: *Hardware › USB Device › Spice Port*). Link **all** usbredir channels together with the other channels at session start — Proxmox tickets expire after ~30 s, so slots cannot be linked later. The channel payload (`SPICE_MSG/MSGC_SPICEVMC_DATA`, or `COMPRESSED_DATA` with LZ4 when `SPICE_SPICEVMC_CAP_DATA_COMPRESS_LZ4` is negotiated) is a raw usbredir byte stream. A slot stays connected for the whole session; devices are attached / detached on it with usbredir `device_connect` / `device_disconnect`.

**Protocol.** Implement usbredir protocol 0.7 (`usbredir/docs/usb-redirection-protocol.md`) in `USBRedirWire` (pure codec) — the client is the **usb-host**, QEMU's `usb-redir` device is the usb-guest. Constants/struct layouts may be transcribed from the protocol document; do not copy `usbredirparser`/`usbredirhost` code (LGPL). Advertise: `connect_device_version`, `filter`, `device_disconnect_ack`, `ep_info_max_packet_size`, `64bits_ids`, `32bits_bulk_length`. Not in v1: bulk streams, buffered bulk receiving, **isochronous transfers** (reply `usb_redir_inval`; webcams/audio devices will not work yet). Attach sequence: `hello` exchange → `ep_info` → `interface_info` → `device_connect`; after `set_configuration`/`set_alt_setting` send `ep_info` + `interface_info` before the status reply. Detach: `device_disconnect`, wait for `device_disconnect_ack` (or a short timeout) before re-using the slot. Control packets are handled in order; data packets (control/bulk/interrupt) complete asynchronously and may be cancelled (`cancel_data_packet`).

**Host backend (`USBHost`).** IOKit + IOUSBHost (`IOUSBHostDevice`, `IOUSBHostInterface`, `IOUSBHostPipe`): enumerate `IOUSBHostDevice` services, hot-plug via `IOServiceAddMatchingNotification`, open with device capture, perform control/bulk/interrupt transfers, poll interrupt-IN endpoints for `start_interrupt_receiving`. Entitlement: `com.apple.security.device.usb`. macOS limitation: devices already claimed by a kernel driver (mass storage, many HID devices, smart-card readers…) can only be captured as root or with Apple's restricted `com.apple.vm.device-access` entitlement — show them as unavailable with that explanation instead of failing silently; vendor-specific devices (dongles, programmers, many printers/scanners) work.

**Policy.** Devices with an HID boot keyboard/mouse interface (interface class 3, subclass 1, protocol 1/2) are never redirected automatically; manual redirection requires an explicit per-attach confirmation warning that the Mac loses the device (needed for security keys such as YubiKey, which expose an OTP keyboard interface). Honour `.vv` `enable-usbredir=0` (hide all USB/ISO UI), `usb-filter` (applies to manual and automatic redirection) and `enable-usb-autoshare` (redirect newly plugged devices that pass the filter, if a slot is free). Release devices on detach, window close and app quit.

**UI.** Toolbar "USB" menu: host devices with a checkmark when redirected, unavailable ones disabled with the reason, free-slot count; "No USB redirection slots" when the VM has none.

## 7b. ISO mounting (virtual CD-ROM)

Goal: pick an `.iso` on the Mac and have it appear in the guest as a CD/DVD drive (e.g. installing drivers or an OS).

- Implemented in `USBEmulation` as an emulated USB 2.0 high-speed **Mass Storage, Bulk-Only Transport** device (class 8, subclass 6 SCSI, protocol 0x50) exposed through a usbredir slot exactly like a real device (§7a). Pure Swift; no entitlements beyond user-selected file access.
- SCSI **MMC CD-ROM** (peripheral type 5, removable, 2048-byte blocks, read-only): TEST UNIT READY, REQUEST SENSE, INQUIRY (incl. VPD 0x00/0x80/0x83), MODE SENSE(6/10), START STOP UNIT (eject), PREVENT ALLOW MEDIUM REMOVAL, READ CAPACITY(10), READ(10)/READ(12), READ TOC/PMA/ATIP (format 0), GET CONFIGURATION, GET EVENT STATUS NOTIFICATION, READ DISC INFORMATION, READ TRACK INFORMATION, MECHANISM STATUS, SET CD SPEED; anything else → CHECK CONDITION / ILLEGAL REQUEST (0x05/0x20/0x00).
- BOT: CBW/CSW validation per spec, Get Max LUN (0) and Bulk-Only Mass Storage Reset class requests, phase-error handling. Reads stream from the file (never load the ISO into memory); file access off the main actor.
- UI: toolbar "Mount ISO…" (file picker, `.iso`/`.img`), mounted image shown with an Eject action; uses one free usbredir slot; disabled when no slot is free.
- Test against QEMU (`-device qemu-xhci -chardev spicevmc,name=usbredir,id=ur0 -device usb-redir,chardev=ur0`): SeaBIOS must enumerate the drive and read its boot catalog.


## 7c. Smartcard passthrough

- SPICE smartcard channel (type 8): each SPICE message 101 carries one VSC message — header `type`, `reader_id`, `length` (uint32, **little-endian** on the SPICE wire; verified against QEMU 8.2 / spice-server 0.15), then data. Types: INIT 1, ERROR 2, READER_ADD 3, READER_REMOVE 4, ATR 5, CARD_REMOVE 6, APDU 7, FLUSH 8, FLUSH_COMPLETE 9.
- Flow: READER_ADD with reader id 0xFFFFFFFF → server answers ERROR(success) with the assigned id → ATR → guest APDUs answered one by one → CARD_REMOVE on unshare. FLUSH is answered with FLUSH_COMPLETE.
- Host side: CryptoTokenKit (`TKSmartCardSlotManager`, `TKSmartCard`), entitlement `com.apple.security.smartcard`. One exclusive session is held while a card is shared so guest APDU sequences are never interleaved with macOS. One shared card at a time. YubiKeys share only their CCID/PIV function this way (FIDO2/OTP stay on the Mac).
- Fallback when the server has no smartcard channel (stock Proxmox QEMU is built without `ccid-card-passthru`): `USBEmulation.EmulatedCCIDReader`, a virtual USB CCID 1.10 reader (class 0x0B, full speed, short-APDU-level exchange, dwMaxCCIDMessageLength 271, NotifySlotChange on interrupt IN) attached through a usbredir slot like the ISO drive; the guest uses its built-in CCID class driver. Written from the USB CCID 1.1 spec. VID 0x1209 / PID 0x0011 (`TODO(verify)`: pid.codes test PID).
- VM side for the channel path: passthrough CCID reader (`-device usb-ccid -chardev spicevmc,id=ccid,name=smartcard -device ccid-card-passthru,chardev=ccid`). `.vv` `enable-smartcard=0` hides the feature; absent = offered when the server lists a smartcard channel.


## 7d. Proxmox VE integration (power control, VM list)

- SPICE has no power control; the app uses the Proxmox REST API (`Packages/SpiceKit/Sources/Proxmox`). A Proxmox `.vv` identifies the VM: `host=pvespiceproxy:<ticket>:<vmid>:<node>::…`, proxy host = node (API on port 8006).
- Auth: API token only (`Authorization: PVEAPIToken=user@realm!name=<secret>`). The secret is stored in the login Keychain (generic password, service `com.pawelwiecaszek.spiceclient.proxmox-token`); server settings (host, port, token ID, pinned fingerprint, cluster CA) in UserDefaults. Never log or persist the secret elsewhere. (SPICE tickets remain memory-only, §9.)
- TLS for the API: macOS trust **or** the cluster CA learned from that host's `.vv` (`pve-root-ca`), with hostname check; or a leaf SHA-256 fingerprint the user explicitly pinned after seeing it. No skip-verification path.
- Endpoints: `GET /cluster/resources?type=vm`, `GET /nodes/{node}/qemu/{vmid}/status/current`, `POST …/status/{start|shutdown|reboot|reset|stop|suspend|resume}`, `POST …/spiceproxy` (fresh connection file → parsed by `VVFileParser`, so it gets the same validation as a downloaded `.vv`). Reset/Stop require confirmation. Token needs VM.Audit, VM.PowerMgmt, VM.Console.

## 8. Input & window behaviour

- Capture keyboard in a first-responder `NSView`; map `NSEvent.keyCode` (macOS virtual key) → PC AT set-1 scancode via a static table in `App/Input/Keymap.swift`. Extended keys (arrows, Ins/Del/Home/End/PgUp/PgDn, right Ctrl/Alt, keypad Enter/÷) use the `0xE0` prefix; key-up sets bit `0x80` on the scancode byte. Verify encoding against `spice-gtk` before shipping.
- Cmd key: configurable — send as Windows/Super, or reserve for macOS shortcuts (default: reserve Cmd+Q/W/H/Tab/Space; send everything else).
- Provide menu items + `.vv`-defined hotkeys for: Send Ctrl+Alt+Del (`secure-attention`), Release cursor, Toggle fullscreen.
- Pointer: client mode = absolute positions, system cursor hidden only over the view. Server mode = pointer lock (`CGAssociateMouseAndMouseCursorPosition(false)` + relative deltas), release via hotkey.
- Sync Caps/Num/Scroll lock state on focus gain.
- Trackpad: scroll deltas accumulated and converted to wheel clicks; pinch ignored.
- Window: SwiftUI chrome with macOS 26 design language (Liquid Glass toolbar) — keep the display area free of overlays; toolbar auto-hides in fullscreen.

---

## 9. Security, privacy, licensing

- **App Sandbox ON.** Entitlements: `com.apple.security.network.client`, `com.apple.security.files.user-selected.read-write`, `com.apple.security.device.usb` (USB redirection, §7a), `com.apple.security.smartcard` (smartcard passthrough, §7c), `com.apple.security.device.audio-input` (record only). Hardened Runtime ON. Nothing else without asking.
- TLS: use only the `.vv` `ca` as anchors when present (`sec_protocol_options_set_verify_block` + `SecTrustSetAnchorCertificates` + `SecTrustSetAnchorCertificatesOnly(true)`), then enforce `host-subject`. **Never** add a "skip verification" path, even for debugging.
- Tickets/passwords: memory only, never logged, never persisted, never in crash reports. Use `privacy: .private` for any host data in `os.Logger`.
- Treat all server data as hostile: bounds-check every length/offset, cap allocations (surface size ≤ 16384², message size ≤ configured limit), fuzz `SpiceWire` and `SpiceCodecs`.
- Hard limits (October 2026 audit; keep them, add a regression test for any new one): `secure-channels` is never downgraded to plain TCP; an unusable `ca` or `host-subject` refuses the connection (never falls back to system trust or hostname checks) and TLS always uses an SSL-server policy; hosts and CONNECT targets are limited to `[A-Za-z0-9-._~:[]%]`; an unreadable `usb-filter` disables USB redirection; the local filter is enforced in `SpiceSession.attachUSB` for every device including emulated ones; USB transfers ≤ 4 MiB each and ≤ 32 MiB / 1024 outstanding per slot, only on endpoints the device has; aggregate surface budget 512 MiB, ≤ 64 video streams, bounded palette cache, renderer backpressure; the server channel list is deduplicated (≤ 16 USB slots); server-supplied text is logged `.private`, sanitized and truncated.
- Re-audit additions (October 2026): `secure-channels` with unknown names or an empty list rejects the file; the vdagent outbox is bounded (one clipboard transfer + 1 MiB) and capability replies are coalesced; the emulated CCID reader stalls new commands while > 4 unread responses are queued; interrupt-receiving starts are idempotent and every stop/detach aborts the device request; any USB/smartcard channel exit releases its device/card and updates the UI; attach/insert reserve before awaiting and recheck for close; `enable-smartcard=0` also blocks smartcard-class USB devices (incl. the emulated reader); palette cache ≤ 1 Mi entries; guest-supplied strings are logged private + sanitized.
- Clipboard (M6): offer the Mac clipboard to the guest only while the session window is key; answer guest requests only with exactly what was offered (pasteboard unchanged since); accept guest data only for a type we requested; check image dimensions before decoding.
- **Licensing:** `spice-protocol` headers are BSD-licensed — constants and layouts may be transcribed. `spice-common`, `spice-gtk`, `spice-html5`, `usbredirparser`/`usbredirhost` are LGPL/other — read for understanding, **do not copy code** (including decoder implementations) into this repo. Write decoders from the spec/behaviour and verify with fixtures. If in doubt, stop and ask.

---

## 10. Coding conventions

- Swift API Design Guidelines. Types `UpperCamelCase`, wire enums mirror spice names in Swift style (`SPICE_MSG_DISPLAY_DRAW_COPY` → `DisplayServerMessage.drawCopy`) with the raw value matching the header.
- `Sendable` everywhere across actor boundaries; no `@unchecked Sendable` without a comment explaining the invariant.
- No force unwraps / `try!` outside tests. Errors are typed enums conforming to `LocalizedError` with user-presentable messages.
- One type per file for anything over ~150 lines. Keep files < 600 lines.
- Public API of `SpiceKit` gets DocC comments.
- Prefer value types; classes only for identity/reference semantics (renderer, texture caches).
- Performance-sensitive code (`SpiceCodecs`, display apply path) gets a benchmark test (`swift test --filter Benchmark`) and must not allocate per pixel/per message in the steady state.

---

## 11. Milestones (work in order; each ends in a working, tested build)

1. **M0 – Skeleton:** Xcode app + `SpiceKit` package, CI script, empty Metal view clearing to a color.
2. **M1 – `.vv`:** parser + fixtures, document type registration, open file → show parsed profile (debug UI).
3. **M2 – Link:** transport (plain/TLS/proxy), link + ticket auth, main channel up, channel list logged.
4. **M3 – Pixels:** display channel with raw bitmaps, `DRAW_FILL`, `DRAW_COPY`, `COPY_BITS`, LZ + QUIC; Metal presents the primary surface.
5. **M4 – Interaction:** inputs + cursor channels, client/server mouse modes, keymap, hotkeys.
   - **M4a – ISO mount (§7b)** and **M4b – USB redirection (§7a)**: usbredir codec + channel, emulated CD-ROM, IOKit host backend, toolbar menus. (Prioritised by the maintainer ahead of M5.)
   - **M4c – Smartcard passthrough (§7c)** and **M6a – Clipboard**: prioritised by the maintainer ahead of M5.
6. **M5 – Performance:** GLZ (+ZLIB-GLZ), LZ4 images, JPEG, H.264/H.265 via VideoToolbox, stream reports, renderer backpressure. *(Done. GLZ/LZ4 were written from a prose format spec and verified against real spice-server captures in `Tests/Fixtures/display`. VP8/VP9 deliberately not supported: spice-server VP9 is profile 1 (4:4:4), rejected by VideoToolbox; VP8 has no macOS decoder; adding libvpx was declined by the maintainer.)*
7. **M6 – Agent:** clipboard, dynamic resolution (monitors config), multi-monitor groundwork. *(Done: one window per display channel (≤ 4), display id on pointer events, multi-monitor layout via VD_AGENT_MONITORS_CONFIG, file transfer to the guest (FILE_XFER_START/STATUS/DATA, 32 KiB chunks paced by the agent outbox, names sanitised to a bare file name). Open: per-head views for single-surface multi-head guests.)*
8. **M7 – Audio:** playback, then record. *(Done: playback/record channels, raw PCM + Opus playback via AudioToolbox (variable frames per packet), jitter buffer ≤ 250 ms, microphone off by default per session and sent only while the guest records (raw PCM; Opus input needs a server built with Opus). Entitlement `device.audio-input` + `NSMicrophoneUsageDescription`.)*
9. **M8 – Polish:** settings, error UX, reconnect, accessibility labels. (Signing and notarization are out of scope: the maintainer builds and runs the app locally.)

Test environments: Proxmox VE VM with QXL or virtio-gpu + `spice-vdagent`; plain QEMU (`-spice port=5930,disable-ticketing=on` for early dev, ticketing + TLS for M2+). Record captures (sanitized) into `Tests/Fixtures`.

---

## 12. How agents should work here

- Plan first for anything touching more than one module; state which milestone the change belongs to.
- Small, reviewable commits; Conventional Commits (`feat(display): …`, `fix(vv): …`).
- When protocol behaviour is unclear, cite the header/proto line you relied on in a code comment.
- Don't invent wire constants — look them up. If you can't verify, leave a `// TODO(verify):` and say so in your summary.
- Never commit real `.vv` files, tickets, hostnames, or CA material from the maintainer's infrastructure.
- Update this file when a fixed decision changes.
