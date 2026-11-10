import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shown when the app is launched without a connection file.
struct WelcomeView: View {
    @State private var isTargeted = false
    @Bindable private var portals = RavadaPortalStore.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "display")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("MacOS Spice Client")
                .font(.largeTitle.weight(.semibold))
            Text("Connect through Proxmox, open your Ravada portal, or choose a virt-viewer connection file (.vv).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button("Open Connection File…") { SessionWindowManager.shared.presentOpenPanel() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Button("Proxmox Virtual Machines…") { MainWindowController.shared.showProxmox() }
                .controlSize(.large)
            Button("Open Ravada Portal…") { MainWindowController.shared.showPortal() }
                .controlSize(.large)
            if !portals.favorites.isEmpty {
                Menu("Favorite Ravada Portals") {
                    ForEach(portals.favorites) { profile in
                        Button(profile.name) { MainWindowController.shared.showPortal(profileID: profile.id) }
                    }
                }
                .accessibilityIdentifier("ravadaFavoritePortals")
            }
            Text("or drop a .vv file here")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(width: 520, height: portals.favorites.isEmpty ? 420 : 470)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.pathExtension.lowercased() == "vv" }
            for url in files { SessionWindowManager.shared.open(url) }
            return !files.isEmpty
        } isTargeted: { isTargeted = $0 }
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        TabView(selection: $settings.selectedSettingsTab) {
            Tab("General", systemImage: "gearshape", value: 0) { general }
            Tab("Proxmox", systemImage: "server.rack", value: 1) { ProxmoxSettingsView(store: .shared) }
            Tab("Ravada", systemImage: "globe", value: 2) { RavadaSettingsView() }
            Tab("Downloads", systemImage: "arrow.down.doc", value: 3) { DownloadSettingsView() }
        }
        .frame(width: 600)
        // Sent here from a session's Power menu: go straight to the Proxmox tab.
        .onChange(of: ProxmoxStore.shared.pendingHost, initial: true) { _, host in
            if host != nil { settings.selectedSettingsTab = 1 }
        }
    }

    private var general: some View {
        Form {
            Section("Keyboard") {
                Toggle("Send ⌘ to the guest as the Windows key", isOn: $settings.sendCommandKeyToGuest)
                Text("⌘Q, ⌘W, ⌘H, ⌘Tab and ⌘Space always stay with macOS. Applies to new sessions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Display") {
                Toggle("Resize the guest to fit the window", isOn: $settings.resizeGuestWithWindow)
                Toggle("Use Retina resolution (one guest pixel per screen pixel)", isOn: $settings.useRetinaResolution)
                Text("Resizing needs the SPICE guest agent (spice-vdagent) in the virtual machine.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Audio") {
                Toggle("Play the virtual machine’s sound", isOn: $settings.playGuestAudio)
                Text("Applies to new sessions. The microphone is off in every session until you switch it on in the toolbar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Connection") {
                Toggle("Reconnect automatically when the connection drops", isOn: $settings.reconnectAutomatically)
                Text("Retries for about two minutes, waiting while the Mac is offline. Proxmox sessions get a fresh ticket through the API (needs the server under Proxmox); a downloaded connection file’s ticket works only once.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Clipboard") {
                Toggle("Share the clipboard with virtual machines", isOn: $settings.shareClipboard)
                Text("Off by default. When on, text and images you copy are shared both ways, and the virtual machine can read your Mac clipboard while its window is active — including what you copied before connecting. Needs spice-vdagent in the guest.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
