<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="MacOS Spice Client icon">
</p>

<h1 align="center">MacOS Spice Client</h1>

<p align="center">
  A native macOS client for SPICE virtual machine consoles: Proxmox VE, QEMU/libvirt and oVirt.
</p>

---

MacOS Spice Client opens the virt-viewer connection files (`.vv`) that Proxmox and other
virtualization platforms hand out and shows the virtual machine in a fast, native Mac
window. The SPICE protocol is implemented from scratch in Swift, the screen is drawn with
Metal, and the app runs fully sandboxed.

## Features

**Connecting**
- Opens `.vv` files directly — double-click the file your browser downloads after clicking
  **SPICE** in Proxmox, or drop it on the app.
- **Virtual Machines** window (⌘0): browse the VMs of your Proxmox servers and connect,
  start, shut down, reboot, pause or stop them, without downloading a file.
- **Power menu** in every Proxmox session window.
- **Ravada portal**: sign in and choose a machine in an embedded browser; SPICE
  connection files open directly in the native viewer. Proxmox remains available separately.
- **Download helper**: optionally watch a chosen browser download folder and open new
  `.vv` files automatically while the app runs.
- **Automatic reconnect** after network drops or sleep, in the same window — shared
  devices, the mounted disc image and the microphone come back on their own.

**Display**
- Metal rendering with Retina support; the guest resolution follows the window size.
- Hardware video decoding (H.264 and H.265 via VideoToolbox) when the server streams video.
- All SPICE image formats: QUIC, LZ, GLZ, LZ4, JPEG and MJPEG.
- Multiple monitors (up to four), each in its own window, with full-screen support.

**Input**
- Full keyboard support with the ⌘ key sent as the Windows key (⌘Q, ⌘Tab and friends stay
  with macOS), Caps Lock sync and Ctrl+Alt+Del.
- Seamless pointer with the guest agent, or a captured pointer for guests without one.
- Hotkeys from the connection file (full screen, release cursor, secure attention).

**Sharing with the virtual machine**
- **Clipboard**: copy and paste text and images in both directions (opt-in in Settings).
- **Files**: drag files onto the VM's screen to copy them into it.
- **Sound**: guest audio plays on the Mac with low latency; the microphone can be switched
  on per session (it is always off until you allow it).
- **USB devices**: redirect devices plugged into the Mac to the VM.
- **Disc images**: insert an `.iso` into the VM as a USB CD/DVD drive.
- **Smartcards and security keys**: share a smartcard or a YubiKey's PIV function with the
  VM — it appears there as a standard USB smartcard reader.

**Security**
- TLS with the connection file's CA as the only trust anchor and host-subject checking;
  secure channels are never downgraded, and unencrypted connections need your confirmation.
- One-time tickets stay in memory only and are wiped after use.
- Proxmox API tokens are stored in the Keychain.
- App Sandbox and Hardened Runtime; clipboard, USB, smartcard and microphone sharing only on request.

## Installation

Requires **macOS 26 Tahoe** or later, on Apple silicon or Intel.

### Homebrew

```bash
brew tap pawelwiecaszek/macos-spice-client https://github.com/pawelwiecaszek/macos-spice-client
brew install --cask macos-spice-client
```

Update with `brew upgrade --cask macos-spice-client`.

### Download

Download the latest `.dmg` from [Releases](https://github.com/pawelwiecaszek/macos-spice-client/releases),
open it and drag **MacOS Spice Client** to Applications.

The app is ad-hoc signed and not notarized by Apple. Each release lists the DMG's SHA-256
checksum (`.sha256` file) so you can verify the download.

The first time you open a downloaded copy, macOS blocks
it: verify the checksum, then open **System Settings › Privacy & Security** and click
**Open Anyway**. The Homebrew cask verifies the checksum but leaves Gatekeeper's quarantine
in place, so the same one-time approval applies.

### Build from source

Needs Xcode 26 or later (with the Metal Toolchain component).

```bash
git clone https://github.com/pawelwiecaszek/macos-spice-client.git
cd macos-spice-client
xcodebuild -project SpiceClient.xcodeproj -scheme SpiceClient -configuration Release \
  -derivedDataPath build build
open "build/Build/Products/Release/MacOS Spice Client.app"
```

The protocol library builds and tests on its own: `cd Packages/SpiceKit && swift test`.

## Using it with Proxmox VE

1. Set the VM's **Display** to **SPICE** (Hardware › Display).
2. Click **Console › SPICE** in the Proxmox web interface and open the downloaded file —
   the ticket inside is valid for a few seconds and only once.

Recommended in the VM:
- **spice-vdagent** (Linux) or the **SPICE guest tools** (Windows) for the clipboard, file
  transfer, a seamless pointer and automatic resolution.
- **USB redirection**: add one *Spice Port* USB device per device you want to share
  (Hardware › Add › USB Device). A free port is also needed for a disc image or smartcard.
- **Sound**: add an audio device with the *SPICE* driver (Hardware › Add › Audio Device).
- **Hardware video decoding**: enable *Video Streaming* (Options › Spice Enhancements).

### Proxmox API access (optional)

For the Virtual Machines window, the Power menu and reconnecting with a fresh ticket, add
your server under **Settings › Proxmox** with an API token (Datacenter › Permissions ›
API Tokens). The token needs **VM.Audit**, **VM.PowerMgmt** and **VM.Console** — for
example the *PVEVMUser* role on `/vms`. If privilege separation is on, give the role to
the token itself, not only to its user.

## Using it with Ravada

1. Save a named HTTPS portal under **Connections › Manage Portals**. An existing portal address
   and browser login are imported automatically.
2. Choose **Open Ravada Portal…** from Connections or the File menu.
3. Sign in and select a machine using the portal. Its SPICE connection opens in a
   native session window; the portal remains available for more connections.

Connections, portal browsing, saved profiles, Proxmox VM browsing and Settings share
one main window. Use **Connections** in a VDI toolbar to return to it; **⌘,** opens
Settings there. Each VDI keeps its own window, which stays open when the main window closes.

Ravada sessions start in a window even if the portal’s connection file requests
fullscreen. Use the session’s fullscreen command to enter fullscreen when wanted.

The portal distinguishes network, certificate, sign-in, permission, and connection-file
errors. Recovery returns to the configured portal so you can choose a machine again;
it does not automatically resubmit the previous action. **Stop** cancels the current
page load or connection download, including a file still being processed.

The portal allows its initial automatic connection after a desktop starts. Once a
connection has been handed off, additional background offers from that page are
ignored. Clicking **View** explicitly still opens a connection. This prevents a
delayed Ravada automatic download from unexpectedly replacing a working viewer.

Use the portal toolbar’s **Diagnostics › Copy Portal Diagnostics** to copy a support
summary. It contains bounded in-memory counters and fixed error categories, without
portal addresses, usernames, passwords, cookies, tickets, or guest contents.

Save multiple profiles and mark frequent ones as favorites for quick access from the
welcome window. Switch profiles from **Saved Portals** in the portal toolbar or the
File menu. Each profile has its own browser login, including profiles using the same
server address. Removing a profile or clearing its login affects only that profile;
running VDI sessions remain open.

Each profile can inherit General preferences or override guest resizing, Retina
resolution, the Command key, clipboard sharing, and audio playback. Overrides apply
to new VDI sessions and are retained on reconnect; they do not change General settings.

**Clear Portal Login** removes that profile’s saved browser data. Certificates must be trusted by macOS; downloading a
connection file never changes portal certificate trust. Ravada API power controls and
automatic ticket renewal are not provided; reopen the portal for a fresh connection.

**Diagnostics › Check Desktop Access** performs one authenticated user-catalog read
using the current portal browser login. It shows an access result and entry count;
continue using the portal to launch a desktop. The check follows no redirects, exports
no cookies and stops on navigation, Stop or leaving the portal. Ravada 2.4.6 may enqueue
its normal desktop-preview refresh while serving this catalog; the client does not
fetch those images or issue start/stop/clone actions. Native desktop browsing and
fresh-ticket reconnect remain later features.

The portal workflow was informed by [spice-mac](https://github.com/BeriBeli/spice-mac).
This app continues to use its own Swift SPICE implementation and Metal renderer.

## Automatically opening browser downloads

Under **Settings › Downloads**, turn on **Open new .vv downloads automatically** and
choose your browser’s download folder. Existing files are ignored. New connection files
open after their contents stabilize and pass validation; browser temporary files are
ignored. Existing warnings for unencrypted connections still apply.

The helper runs while the app is running, including after all windows close. It stops
when you quit or turn it off. Folder access lasts for the current app session, so choose
the folder again after restarting. No login item or background service is installed.

## License

[MIT](LICENSE). SPICE protocol constants come from the BSD-licensed
[spice-protocol](https://gitlab.freedesktop.org/spice/spice-protocol) headers.
