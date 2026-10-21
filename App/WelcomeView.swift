import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shown when the app is launched without a connection file.
struct WelcomeView: View {
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "display")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("MacOS Spice Client")
                .font(.largeTitle.weight(.semibold))
            Text("Open a virt-viewer connection file (.vv), for example the one your browser downloads when you click “SPICE” in Proxmox VE.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button("Open Connection File…") { SessionWindowManager.shared.presentOpenPanel() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Button("Virtual Machines…") { VMListWindow.shared.show() }
                .controlSize(.large)
            Text("or drop a .vv file here")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(width: 520, height: 360)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.pathExtension.lowercased() == "vv" }
            for url in files { SessionWindowManager.shared.open(url) }
            return !files.isEmpty
        } isTargeted: { isTargeted = $0 }
    }
}

/// AppKit-managed welcome window (SwiftUI's own windows would also open on file launches).
@MainActor
final class WelcomeWindow {
    static let shared = WelcomeWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: WelcomeView())
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.title = String(localized: "Welcome")
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window?.close()
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: 0) { general }
            Tab("Proxmox", systemImage: "server.rack", value: 1) { ProxmoxSettingsView(store: .shared) }
        }
        .frame(width: 520)
        // Sent here from a session's Power menu: go straight to the Proxmox tab.
        .onChange(of: ProxmoxStore.shared.pendingHost, initial: true) { _, host in
            if host != nil { tab = 1 }
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
