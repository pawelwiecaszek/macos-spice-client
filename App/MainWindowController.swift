import AppKit
import Observation
import SpiceKit
import SwiftUI
import WebKit

/// One navigation window for connections, portals and preferences; VDI windows are independent.
@MainActor
@Observable
final class MainWindowController: NSObject, NSWindowDelegate {
    enum Page { case home, portal, portals, desktops, proxmox, settings, help }
    static let shared = MainWindowController()
    @ObservationIgnored private(set) var window: NSWindow?
    private(set) var page: Page = .home
    private(set) var model: RavadaPortalModel?
    private(set) var displayedProfile: RavadaPortalProfile?
    private(set) var desktopStore: RavadaDesktopStore?
    private(set) var helpTopicID = "start"
    private(set) var helpRequestID = UUID()
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

    func showHelp(topicID: String = "start") {
        SessionWindowManager.shared.keyController?.releaseCursor()
        helpTopicID = topicID
        helpRequestID = UUID()
        navigate(to: .help)
    }

    func showCurrentPage() { present() }

    func showPortal(profileID: UUID? = nil) {
        if page != .portal { model?.cancelReconnectRead() }
        if page == .desktops { desktopStore?.deactivate() }
        if let profileID {
            do { try portals.select(profileID) } catch { return }
        }
        let profile = portals.selectedProfile
        if model == nil || displayedProfile != profile {
            desktopStore?.deactivate()
            desktopStore = nil
            model?.stop()
            if let profile, let url = profile.url {
                model = RavadaPortalModel(
                    portalURL: url, dataStore: WKWebsiteDataStore(forIdentifier: profile.websiteDataStoreID),
                    openConnectionWithIdentity: { [weak self, portals] connection, machineID in
                        guard self?.page == .portal, self?.displayedProfile?.id == profile.id,
                              let current = portals.profiles.first(where: { $0.id == profile.id }),
                              current.address == profile.address,
                              current.websiteDataStoreID == profile.websiteDataStoreID else { return false }
                        let settings = AppSettings.shared.applying(current.preferences)
                        return SessionWindowManager.shared.openSession(connection, settings: settings,
                            origin: .ravada(RavadaSessionOrigin(profile: profile, machineID: machineID)))
                    })
            } else {
                model = nil
            }
            displayedProfile = profile
            model?.load()
        }
        model?.resume()
        if model?.hasCommittedDocument == false && model?.isLoading == false && model?.webView.isLoading == false { model?.load() }
        page = .portal
        present()
    }

    func showDesktops() {
        guard let profile = portals.selectedProfile else { showPortals(); return }
        #if DEBUG
        if let fixture = RavadaDesktopFixture.store(profile: profile, defaults: portals.defaults) {
            desktopStore?.deactivate()
            desktopStore = fixture
            displayedProfile = profile
            navigate(to: .desktops)
            fixture.activate()
            return
        }
        #endif
        guard let model, displayedProfile == profile, model.hasCommittedDocument, !model.isLoading, model.webView.url != nil else {
            // Establish an authenticated main-frame document before using its cookie context.
            showPortal(profileID: profile.id)
            return
        }
        if desktopStore == nil {
            do {
                let reader = try RavadaBrowserTransport(portalURL: model.portalURL, webView: model.webView)
                desktopStore = RavadaDesktopStore(profile: profile, defaults: portals.defaults,
                    request: { [weak self] request in
                        guard self?.canUseDesktopProfile(profile) == true else { throw RavadaBrokerError.cancelled }
                        let response = try await reader.request(request)
                        guard self?.canUseDesktopProfile(profile) == true else { throw RavadaBrokerError.cancelled }
                        return response
                    }, cancel: { reader.cancel() }, open: { [weak self] connection, machineID in
                        guard self?.canUseDesktopProfile(profile) == true,
                              let current = self?.portals.selectedProfile else { return false }
                        return SessionWindowManager.shared.openSession(connection,
                            settings: AppSettings.shared.applying(current.preferences),
                            origin: .ravada(RavadaSessionOrigin(profile: profile, machineID: machineID)))
                    })
            } catch { showPortal(profileID: profile.id); return }
        }
        navigate(to: .desktops)
        desktopStore?.activate()
    }

    /// Explicit VDI reconnect may read the preserved document while its portal UI is
    /// paused. It never navigates a hidden portal or admits a browser download.
    func reconnectProfile(for identity: RavadaSessionOrigin) async throws -> RavadaReconnectTicket {
        guard let model, let displayedProfile, identity.matches(displayedProfile),
              desktopStore?.isBusy != true else { throw RavadaBrokerError.signInRequired }
        let validate: @MainActor () throws -> Void = { [weak self, weak model] in
            guard let self, let model, self.model === model,
                  self.portals.profiles.contains(where: identity.matches) else {
                throw RavadaBrokerError.portalRequired
            }
        }
        try validate()
        return try await model.reconnectProfile(for: identity, validate: validate)
    }

    private func canUseDesktopProfile(_ profile: RavadaPortalProfile) -> Bool {
        guard model?.hasReconnectRequest != true, page == .desktops, displayedProfile?.id == profile.id,
              let current = portals.selectedProfile else { return false }
        return current.id == profile.id && current.address == profile.address
            && current.websiteDataStoreID == profile.websiteDataStoreID
    }

    private func navigate(to page: Page) {
        if self.page != page { model?.cancelReconnectRead() }
        if self.page == .portal && page != .portal { model?.pause() }
        if self.page == .desktops && page != .desktops { desktopStore?.deactivate() }
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
        desktopStore?.deactivate()
        desktopStore = nil
        model?.stop()
        model = nil
        displayedProfile = nil
        page = .home
        window = nil
    }

    func windowDidMiniaturize(_ notification: Notification) {
        model?.cancelReconnectRead()
        desktopStore?.deactivate()
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        if page == .desktops { desktopStore?.activate() }
    }

    func close() {
        desktopStore?.deactivate()
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
        if displayedProfile?.id == old.id { model?.cancelReconnectRead() }
        if displayedProfile?.id == old.id { desktopStore?.deactivate(); desktopStore = nil }
        if old.address != profile.address || old.websiteDataStoreID != profile.websiteDataStoreID {
            clearPortalIfDisplaying(old.id)
        } else if displayedProfile?.id == old.id {
            displayedProfile = profile
        }
        if old.websiteDataStoreID != profile.websiteDataStoreID { eraseBrowserData(old.websiteDataStoreID) }
    }

    private func clearPortalIfDisplaying(_ id: UUID) {
        guard displayedProfile?.id == id else { return }
        desktopStore?.deactivate()
        desktopStore = nil
        model?.stop()
        model = nil
        displayedProfile = nil
        if page == .portal || page == .desktops { navigate(to: .portals) }
    }

    private func eraseBrowserData(_ id: UUID) {
        WKWebsiteDataStore(forIdentifier: id).removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }
}
