import AppKit
import SwiftUI

@main
struct SpiceClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(settings: AppSettings.shared)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { MainWindowController.shared.showSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("Connections") { MainWindowController.shared.showCurrentPage() }
                Button("Open Connection File…") { SessionWindowManager.shared.presentOpenPanel() }
                    .keyboardShortcut("o")
                Button("Virtual Machines…") { MainWindowController.shared.showProxmox() }
                    .keyboardShortcut("0")
                Button("My Ravada Desktops…") { MainWindowController.shared.showDesktops() }
                Button("Open Ravada Portal…") { MainWindowController.shared.showPortal() }
                Menu("Saved Ravada Portals") { RavadaPortalMenuContent() }
            }
            CommandGroup(replacing: .help) {
                Button("MacOS Spice Client Help") { MainWindowController.shared.showHelp() }
                    .keyboardShortcut("?", modifiers: [.command, .shift])
                Button("Keyboard & Mouse Help") { MainWindowController.shared.showHelp(topicID: "keyboard") }
                Button("Troubleshooting") { MainWindowController.shared.showHelp(topicID: "troubleshooting") }
            }
            CommandMenu("Session") {
                Button("Send Ctrl+Alt+Del") { SessionWindowManager.shared.keyController?.sendCtrlAltDelete() }
                    .keyboardShortcut(.delete, modifiers: [.control, .option, .command])
                Button("Release Cursor") { SessionWindowManager.shared.keyController?.releaseCursor() }
                Divider()
                Button("Toggle Full Screen") { SessionWindowManager.shared.keyController?.toggleFullscreen() }
                    .keyboardShortcut("f", modifiers: [.control, .command])
            }
        }
    }
}

/// Handles document opening (Finder double-click, browser "Open") and app lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openedFileAtLaunch = false
    private var helpShortcut: ClientHelpShortcut?

    func application(_ application: NSApplication, open urls: [URL]) {
        openedFileAtLaunch = true
        for url in urls { SessionWindowManager.shared.open(url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        helpShortcut = ClientHelpShortcut()
        // Files opened at launch arrive before this point; otherwise show the welcome window.
        if !openedFileAtLaunch && !SessionWindowManager.shared.hasSessions {
            MainWindowController.shared.showHome()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.showCurrentPage()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        helpShortcut?.stop()
        DownloadWatcher.shared.stop()
        MainWindowController.shared.close()
        SessionWindowManager.shared.closeAll()
    }
}
