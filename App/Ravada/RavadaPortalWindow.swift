import AppKit
import SwiftUI
import WebKit

@MainActor
final class RavadaPortalWindow: NSObject, NSWindowDelegate {
    static let shared = RavadaPortalWindow()
    private var window: NSWindow?
    private var model: RavadaPortalModel?

    private var displayedProfile: RavadaPortalProfile?

    func show(profileID: UUID? = nil) {
        let portals = RavadaPortalStore.shared
        if let profileID {
            do { try portals.select(profileID) } catch { return }
        }
        let profile = portals.selectedProfile
        if window == nil || displayedProfile != profile {
            model?.stop()
            let model: RavadaPortalModel?
            if let profile, let url = profile.url {
                model = RavadaPortalModel(
                    portalURL: url, dataStore: WKWebsiteDataStore(forIdentifier: profile.websiteDataStoreID),
                    openConnection: { connection in
                        guard let current = portals.profiles.first(where: { $0.id == profile.id }),
                              current.address == profile.address,
                              current.websiteDataStoreID == profile.websiteDataStoreID else { return false }
                        let settings = AppSettings.shared.applying(current.preferences)
                        return SessionWindowManager.shared.openSession(connection, settings: settings)
                    })
            } else {
                model = nil
            }
            self.model = model
            displayedProfile = profile
            let hosting = NSHostingController(rootView: RavadaPortalView(model: model, profileID: profile?.id))
            hosting.sceneBridgingOptions = [.toolbars, .title]
            let window = self.window ?? NSWindow(contentViewController: hosting)
            window.contentViewController = hosting
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = String(localized: "Ravada Portal")
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 1000, height: 720))
            window.contentMinSize = NSSize(width: 640, height: 480)
            if self.window == nil { window.center() }
            self.window = window
            model?.load()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        model?.stop()
        model = nil
        displayedProfile = nil
        window = nil
    }

    func close() {
        model?.stop()
        window?.close()
    }

    func clearLogin(profileID: UUID) throws {
        guard let oldID = try RavadaPortalStore.shared.rotateLogin(profileID: profileID) else { return }
        closeIfDisplaying(profileID)
        eraseBrowserData(oldID)
    }

    func removed(_ profile: RavadaPortalProfile) {
        closeIfDisplaying(profile.id)
        eraseBrowserData(profile.websiteDataStoreID)
    }

    func updated(from old: RavadaPortalProfile, to profile: RavadaPortalProfile) {
        if old.address != profile.address || old.websiteDataStoreID != profile.websiteDataStoreID {
            closeIfDisplaying(old.id)
        } else if displayedProfile?.id == old.id {
            displayedProfile = profile
        }
        if old.websiteDataStoreID != profile.websiteDataStoreID { eraseBrowserData(old.websiteDataStoreID) }
    }

    private func closeIfDisplaying(_ id: UUID) {
        if displayedProfile?.id == id { close() }
    }

    private func eraseBrowserData(_ id: UUID) {
        WKWebsiteDataStore(forIdentifier: id).removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

}

private struct RavadaPortalView: View {
    let model: RavadaPortalModel?
    let profileID: UUID?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let model {
                BrowserContent(model: model)
            } else {
                ContentUnavailableView {
                    Label("Set Up Ravada", systemImage: "globe")
                } description: {
                    Text("Add your Ravada portal’s HTTPS address in Settings › Ravada.")
                } actions: {
                    Button("Open Settings…") {
                        AppSettings.shared.selectedSettingsTab = 2
                        openSettings()
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Menu("Saved Portals", systemImage: "globe") {
                    RavadaPortalMenuContent(selectedID: profileID)
                }
                .accessibilityLabel("Saved Ravada Portals")
                .accessibilityIdentifier("ravadaPortalSwitcher")
            }
        }
    }
}

private struct BrowserContent: View {
    @Bindable var model: RavadaPortalModel

    var body: some View {
        PortalWebView(webView: model.webView)
            .safeAreaInset(edge: .bottom) {
                if model.requiresSignIn {
                    Text("Sign in through the portal to continue.")
                        .font(.callout)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                } else if let notice = model.launchNotice {
                    Text(notice)
                        .font(.callout)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button("Back", systemImage: "chevron.backward") { model.webView.goBack() }
                        .disabled(!model.canGoBack)
                    Button("Forward", systemImage: "chevron.forward") { model.webView.goForward() }
                        .disabled(!model.canGoForward)
                    Button("Reload Portal", systemImage: "arrow.clockwise") { model.load() }
                        .help("Return to the portal without resubmitting the previous action")
                    Button("Stop", systemImage: "xmark") { model.cancelCurrentAction() }
                        .disabled(!model.isBusy)
                        .accessibilityIdentifier("stopPortalAction")
                    Menu("Diagnostics", systemImage: "stethoscope") {
                        Button("Copy Portal Diagnostics") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.diagnostics.summary, forType: .string)
                        }
                    }
                    .accessibilityIdentifier("portalDiagnosticsMenu")
                    .help("Copy counters and error categories without addresses or credentials")
                    if model.isBusy {
                        ProgressView().controlSize(.small).accessibilityLabel("Loading portal")
                    }
                }
            }
            .alert("Portal Action Failed", isPresented: Binding(
                get: { model.failure != nil },
                set: { if !$0 { model.failure = nil } }
            )) {
                if let failure = model.failure {
                    Button(recoveryTitle(failure.recovery)) { model.load() }
                }
                Button("Dismiss", role: .cancel) { model.failure = nil }
            } message: {
                Text(model.failure?.message ?? "")
            }
    }

    private func recoveryTitle(_ recovery: RavadaPortalFailure.Recovery) -> String {
        switch recovery {
        case .reloadPortal: String(localized: "Reload Portal")
        case .signIn: String(localized: "Sign In Again")
        case .chooseMachine: String(localized: "Return to Portal")
        }
    }
}

private struct PortalWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
