# Design

## Source of truth
Active, 2026-11-10. Native macOS 26+ app: one main navigation window and independent VDI windows.
Evidence: AGENTS.md §§2, 7e, 8; App/WelcomeView.swift; App/Ravada; current UI tests.
No existing DESIGN.md or separate design tokens were present. Phase 2 is local-only.

## Brand
Native, restrained, clear. Use system controls and visible connection state. Avoid
custom chrome, web-style dashboards in Settings, and decorative guest-display overlays.

## Product goals
Save named Ravada portal profiles, favorite frequent connections, and apply optional
per-portal session preferences. Preserve Proxmox/manual files and the current login.
Success: migration loses no address/login; profile switching leaves running VDI sessions alone.
Non-goals: native desktop catalog, machine favorites, broker API, credential entry outside WebKit.

## Personas and jobs
A macOS VDI user connects to one or more Ravada portals, remembers preferred sharing
and display settings, and uses LDAP credentials only in the portal's login page.

## Information architecture
One main navigation window contains Connections, Ravada portal, saved profiles,
Proxmox VM browsing and Settings. VDI windows remain separate. Welcome keeps Open File,
Proxmox and Open Ravada; favorites offer direct portal launch.
Settings > Ravada contains a saved-profile picker, New, editable name/HTTPS address,
favorite flag, session overrides, Save/Open, Remove and Clear Portal Login.
The portal toolbar offers saved-profile switching and Connections/Home. Profile editing
can return to the retained portal. A Ravada Portal navigation button is available
on every other page, even before a browser session has been opened. Cmd+, and each VDI Connections button bring the
existing main window forward; focusing it must preserve unsaved drafts. VDI windows
remain independent of portal selection, removal and closing the main window.

## Design principles
Explicit save boundaries; validate before persistence. Keep inherited General settings
visible in preference pickers. A profile's browser data belongs to that profile.
Do not reset global preferences or close a VDI while editing a saved portal.

## Visual language
System semantic colors, SwiftUI Form sections, system typography and standard spacing.
Use native toolbar/menu/sidebar conventions already present; no parallel token system.
Favorites use star imagery; selection uses system checkmarks. Motion follows macOS defaults.

## Components
Existing: WelcomeView, Settings TabView/Form, PortalWebView and native NSWindow toolbars.
New: saved-profile editor and shared saved-portal menu content. Reuse native Picker,
TextField, Toggle, Button, Menu and confirmation dialogs. Validation uses semantic red.

## Accessibility
Native labels and keyboard traversal; provide stable identifiers for profile/editor actions.
Fields and icon controls need meaningful accessibility names. Use system contrast,
Dynamic Type where applicable and reduced-motion behavior; color is never the only state cue.

## Responsive behavior
Desktop-only macOS. Settings forms scroll as required at the existing 600-point width.
Profile labels truncate in compact menus; the full name remains available to accessibility.
The remote desktop retains existing resizing and fullscreen controls.

## Interaction states
Empty: editor invites saving a first portal. Invalid: explain HTTPS/name errors inline.
Corrupt saved metadata: show recovery guidance and preserve data; never silently overwrite it.
Save/Open success selects the profile. Removing a profile confirms scope and clears only
its browser data; Clear Portal Login rotates only that profile's login store.
Loading/error/offline/Stop behavior retains Phase 1 recovery and duplicate-launch protections.
Hidden portal pages admit no navigation or connection handoffs, including late callbacks;
returning preserves the browser document and permits a deliberate View action.

## Content voice
Use Portal, Favorite, Use General setting, On/Off, Save Portal and Clear Portal Login.
Explain that overrides apply to new VDI sessions. Do not expose cookie IDs or framework names.

## Implementation constraints
SwiftUI/AppKit/WebKit only, no dependencies or new entitlements. Never persist tickets,
passwords or copied cookies in profile metadata. Migrate the legacy origin store ID into
the initial profile; new profiles get independent browser stores, including same-origin profiles.
Require automated migration/isolation/preference tests and UI screenshots before local acceptance.

## Open questions
- [ ] User live acceptance of adding/switching profiles and preference inheritance (owner: user).
- [ ] Machine-level favorites await the later native desktop catalog (owner: future phase).
