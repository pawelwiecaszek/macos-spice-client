import Foundation
import Observation

/// User preferences (UserDefaults-backed).
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        didSet { defaults.set(sendCommandKeyToGuest, forKey: Keys.sendCommandKeyToGuest) }
    }

    /// Ask the guest agent to match the window size.
    var resizeGuestWithWindow: Bool {
        didSet { defaults.set(resizeGuestWithWindow, forKey: Keys.resizeGuestWithWindow) }
    }

    /// Retina/HiDPI: guest resolution in device pixels instead of points.
    var useRetinaResolution: Bool {
        didSet { defaults.set(useRetinaResolution, forKey: Keys.useRetinaResolution) }
    }

    /// Copy & paste between the Mac and the guest (needs spice-vdagent in the guest).
    var shareClipboard: Bool {
        didSet { defaults.set(shareClipboard, forKey: Keys.shareClipboard) }
    }

    /// Play the guest's sound on this Mac (applies to new sessions).
    var playGuestAudio: Bool {
        didSet { defaults.set(playGuestAudio, forKey: Keys.playGuestAudio) }
    }

    /// Reconnect by itself when the network drops a session (M8).
    var reconnectAutomatically: Bool {
        didSet { defaults.set(reconnectAutomatically, forKey: Keys.reconnectAutomatically) }
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
