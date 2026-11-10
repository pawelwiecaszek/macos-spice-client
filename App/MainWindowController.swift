import AppKit
import Observation
import SwiftUI
import WebKit

/// One navigation window for connections, portals and preferences; VDI windows are independent.
@MainActor
@Observable
final class MainWindowController: NSObject, NSWindowDelegate {
    enum Page { case home, portal, portals, proxmox, settings }
    static let shared = MainWindowController()
    @ObservationIgnored private(set) var window: NSWindow?
    private(set) var page: Page = .home
    private(set) var model: RavadaPortalModel?
    private(set) var displayedProfile: RavadaPortalProfile?
    @ObservationIgnored private let portals: RavadaPortalStore

    init(portals: RavadaPortalStore = .shared) {
        self.portals = portals
        super.init()
    }

    func showHome() { navigate(to: .home) }
    func showPortals() { navigate(to: .portals) }
    func showProxmox() { navigate(to: .proxmox) }

    func showSettings(tab: Int? = nil) {
        if let tab { AppSettings.shared.selectedSettingsTab = tab }
        navigate(to: .settings)
    }

    func showCurrentPage() { present() }

    func showPortal(profileID: UUID? = nil) {
        if let profileID {
            do { try portals.select(profileID) } catch { return }
        }
        let profile = portals.selectedProfile
        if model == nil || displayedProfile != profile {
            model?.stop()
            if let profile, let url = profile.url {
                model = RavadaPortalModel(
                    portalURL: url, dataStore: WKWebsiteDataStore(forIdentifier: profile.websiteDataStoreID),
                    openConnection: { [weak self, portals] connection in
                        guard self?.page == .portal, self?.displayedProfile?.id == profile.id,
                              let current = portals.profiles.first(where: { $0.id == profile.id }),
                              current.address == profile.address,
                              current.websiteDataStoreID == profile.websiteDataStoreID else { return false }
                        let settings = AppSettings.shared.applying(current.preferences)
                        return SessionWindowManager.shared.openSession(connection, settings: settings)
                    })
            } else {
                model = nil
            }
            displayedProfile = profile
            model?.load()
        }
        model?.resume()
        page = .portal
        present()
    }

    private func navigate(to page: Page) {
        if self.page == .portal && page != .portal { model?.pause() }
        self.page = page
        present()
    }

    private func present() {
        if window == nil {
            let hosting = NSHostingController(rootView: MainWindowView(navigation: self))
            hosting.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.identifier = NSUserInterfaceItemIdentifier("connectionsWindow")
            window.title = String(localized: "MacOS Spice Client")
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 1000, height: 720))
            window.contentMinSize = NSSize(width: 640, height: 480)
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        model?.stop()
        model = nil
        displayedProfile = nil
        page = .home
        window = nil
    }

    func close() {
        model?.stop()
        window?.close()
    }

    func clearLogin(profileID: UUID) throws {
        guard let oldID = try portals.rotateLogin(profileID: profileID) else { return }
        clearPortalIfDisplaying(profileID)
        eraseBrowserData(oldID)
    }

    func removed(_ profile: RavadaPortalProfile) {
        clearPortalIfDisplaying(profile.id)
        eraseBrowserData(profile.websiteDataStoreID)
    }

    func updated(from old: RavadaPortalProfile, to profile: RavadaPortalProfile) {
        if old.address != profile.address || old.websiteDataStoreID != profile.websiteDataStoreID {
            clearPortalIfDisplaying(old.id)
        } else if displayedProfile?.id == old.id {
            displayedProfile = profile
        }
        if old.websiteDataStoreID != profile.websiteDataStoreID { eraseBrowserData(old.websiteDataStoreID) }
    }

    private func clearPortalIfDisplaying(_ id: UUID) {
        guard displayedProfile?.id == id else { return }
        model?.stop()
        model = nil
        displayedProfile = nil
        if page == .portal { navigate(to: .portals) }
    }

    private func eraseBrowserData(_ id: UUID) {
        WKWebsiteDataStore(forIdentifier: id).removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }
}
