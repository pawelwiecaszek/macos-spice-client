import AppKit
import Foundation
import SpiceKit
import Testing
@testable import SpiceClient

@MainActor
struct MainWindowNavigationTests {
    @Test func navigationAndFocusKeepOneNativeWindowAndHostingController() throws {
        let suite = "main-navigation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = MainWindowController(portals: RavadaPortalStore(defaults: defaults))
        defer { navigation.close() }
        navigation.showHome()
        let window = try #require(navigation.window)
        let host = try #require(window.contentViewController)
        navigation.showPortals()
        #expect(navigation.window === window)
        navigation.showCurrentPage()
        #expect(window.contentViewController === host)
        navigation.showHelp(topicID: "keyboard")
        #expect(navigation.page == .help)
        #expect(navigation.helpTopicID == "keyboard")
        #expect(navigation.window === window)
        navigation.showSettings(tab: 0)
        #expect(navigation.window === window)
        navigation.showHome()
        #expect(window.contentViewController === host)
    }

    @Test func closingTheNavigationWindowDoesNotCloseAnIndependentVDI() throws {
        var profile = ConnectionProfile(host: "example.invalid")
        profile.tlsPort = 5901
        profile.title = "Synthetic window lifecycle VDI"
        #expect(SessionWindowManager.shared.openSession(profile))
        let vdi = try #require(NSApp.windows.first { $0.title == "Synthetic window lifecycle VDI" })
        defer { vdi.close() }
        let navigation = MainWindowController()
        navigation.showHome()
        navigation.showHelp()
        #expect(vdi.isVisible)
        navigation.close()
        #expect(navigation.window == nil)
        #expect(SessionWindowManager.shared.hasSessions)
        #expect(vdi.isVisible)
    }
}
