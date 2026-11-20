import AppKit

/// Routes the standard Help chord locally before text editors or captured guest input
/// consume it. The app delegate owns this monitor for the application lifetime.
@MainActor
final class ClientHelpShortcut {
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Self.matches(event) else { return event }
            let repeated = event.isARepeat
            // AppKit delivers local keyboard monitors on the main application event loop.
            // Only value metadata enters this actor closure; NSEvent stays in its caller.
            MainActor.assumeIsolated {
                if !repeated { MainWindowController.shared.showHelp() }
            }
            return nil
        }
    }

    nonisolated static func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command),
              event.modifierFlags.intersection([.control, .option]).isEmpty else { return false }
        return event.characters == "?" || event.charactersIgnoringModifiers == "?"
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
