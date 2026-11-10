import Foundation
import Observation

/// User preferences (UserDefaults-backed).
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults: UserDefaults
    private let persistChanges: Bool
    /// Navigation state for opening a specific Settings pane from another window.
    var selectedSettingsTab = 0

    init(defaults: UserDefaults = .standard, persistChanges: Bool = true) {
        self.defaults = defaults
        self.persistChanges = persistChanges
        defaults.register(defaults: [
            Keys.sendCommandKeyToGuest: true,
            Keys.resizeGuestWithWindow: true,
            Keys.useRetinaResolution: false,
            // Off until the user opts in: a guest could otherwise read whatever is on the
            // Mac clipboard when a session starts.
            Keys.shareClipboard: false,
            Keys.playGuestAudio: true,
            Keys.reconnectAutomatically: true,
        ])
        reconnectAutomatically = defaults.bool(forKey: Keys.reconnectAutomatically)
        playGuestAudio = defaults.bool(forKey: Keys.playGuestAudio)
        shareClipboard = defaults.bool(forKey: Keys.shareClipboard)
        sendCommandKeyToGuest = defaults.bool(forKey: Keys.sendCommandKeyToGuest)
        resizeGuestWithWindow = defaults.bool(forKey: Keys.resizeGuestWithWindow)
        useRetinaResolution = defaults.bool(forKey: Keys.useRetinaResolution)
    }

    /// Send ⌘ as the Windows/Super key (⌘Q, ⌘W, ⌘H, ⌘Tab and ⌘Space stay with macOS).
    var sendCommandKeyToGuest: Bool {
        didSet { persist(sendCommandKeyToGuest, forKey: Keys.sendCommandKeyToGuest) }
    }

    /// Ask the guest agent to match the window size.
    var resizeGuestWithWindow: Bool {
        didSet { persist(resizeGuestWithWindow, forKey: Keys.resizeGuestWithWindow) }
    }

    /// Retina/HiDPI: guest resolution in device pixels instead of points.
    var useRetinaResolution: Bool {
        didSet { persist(useRetinaResolution, forKey: Keys.useRetinaResolution) }
    }

    /// Copy & paste between the Mac and the guest (needs spice-vdagent in the guest).
    var shareClipboard: Bool {
        didSet { persist(shareClipboard, forKey: Keys.shareClipboard) }
    }

    /// Play the guest's sound on this Mac (applies to new sessions).
    var playGuestAudio: Bool {
        didSet { persist(playGuestAudio, forKey: Keys.playGuestAudio) }
    }

    /// Reconnect by itself when the network drops a session (M8).
    var reconnectAutomatically: Bool {
        didSet { persist(reconnectAutomatically, forKey: Keys.reconnectAutomatically) }
    }

    /// Portal overrides are a session snapshot, never writes to General preferences.
    func applying(_ preferences: RavadaPortalPreferences) -> AppSettings {
        guard !preferences.isEmpty else { return self }
        let result = AppSettings(defaults: defaults, persistChanges: false)
        result.sendCommandKeyToGuest = preferences.sendCommandKeyToGuest ?? sendCommandKeyToGuest
        result.resizeGuestWithWindow = preferences.resizeGuestWithWindow ?? resizeGuestWithWindow
        result.useRetinaResolution = preferences.useRetinaResolution ?? useRetinaResolution
        result.shareClipboard = preferences.shareClipboard ?? shareClipboard
        result.playGuestAudio = preferences.playGuestAudio ?? playGuestAudio
        result.reconnectAutomatically = reconnectAutomatically
        return result
    }

    private func persist(_ value: Bool, forKey key: String) {
        if persistChanges { defaults.set(value, forKey: key) }
    }

    private enum Keys {
        static let reconnectAutomatically = "reconnectAutomatically"
        static let playGuestAudio = "playGuestAudio"
        static let shareClipboard = "shareClipboard"
        static let sendCommandKeyToGuest = "sendCommandKeyToGuest"
        static let resizeGuestWithWindow = "resizeGuestWithWindow"
        static let useRetinaResolution = "useRetinaResolution"
    }
}
