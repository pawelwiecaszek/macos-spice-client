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
            CommandGroup(replacing: .newItem) {
                Button("Open Connection File…") { SessionWindowManager.shared.presentOpenPanel() }
                    .keyboardShortcut("o")
                Button("Virtual Machines…") { VMListWindow.shared.show() }
                    .keyboardShortcut("0")
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

    func application(_ application: NSApplication, open urls: [URL]) {
        openedFileAtLaunch = true
        for url in urls { SessionWindowManager.shared.open(url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Files opened at launch arrive before this point; otherwise show the welcome window.
        if !openedFileAtLaunch && !SessionWindowManager.shared.hasSessions {
            WelcomeWindow.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WelcomeWindow.shared.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        SessionWindowManager.shared.closeAll()
    }
}
