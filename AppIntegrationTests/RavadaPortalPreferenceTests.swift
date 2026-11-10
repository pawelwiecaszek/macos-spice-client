import Foundation
import Testing
@testable import SpiceClient

@MainActor
struct RavadaPortalPreferenceTests {
    @Test func overridesAreSessionOnlyAndDoNotChangeGeneralOrOtherPortals() throws {
        let suite = "portal-preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let general = AppSettings(defaults: defaults)
        general.shareClipboard = false
        general.playGuestAudio = true
        general.resizeGuestWithWindow = true
        let original = defaults.persistentDomain(forName: suite) as NSDictionary?
        var profile = RavadaPortalPreferences()
        profile.shareClipboard = true
        profile.playGuestAudio = false
        let session = general.applying(profile)
        #expect(session !== general)
        #expect(session.shareClipboard)
        #expect(!session.playGuestAudio)
        #expect(session.resizeGuestWithWindow)
        #expect(!general.shareClipboard)
        #expect(general.playGuestAudio)
        // Changing a session snapshot must not write back to the shared defaults.
        session.useRetinaResolution = true
        #expect((defaults.persistentDomain(forName: suite) as NSDictionary?) == original)
        #expect(!AppSettings(defaults: defaults).shareClipboard)
    }

    @Test func unconfiguredPortalRetainsExistingGeneralSettingsBehavior() throws {
        let suite = "portal-preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let general = AppSettings(defaults: defaults)
        let inherited = general.applying(.init())
        #expect(inherited === general)
        general.useRetinaResolution = true
        #expect(inherited.useRetinaResolution)
    }

    @Test func separatePortalOverridesDoNotAffectEachOther() throws {
        let suite = "portal-preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let general = AppSettings(defaults: defaults)
        var first = RavadaPortalPreferences()
        first.useRetinaResolution = true
        first.sendCommandKeyToGuest = false
        var second = RavadaPortalPreferences()
        second.useRetinaResolution = false
        let a = general.applying(first)
        let b = general.applying(second)
        #expect(a.useRetinaResolution)
        #expect(!b.useRetinaResolution)
        #expect(!a.sendCommandKeyToGuest)
        #expect(b.sendCommandKeyToGuest == general.sendCommandKeyToGuest)
    }
}
