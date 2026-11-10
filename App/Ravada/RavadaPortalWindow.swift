import AppKit
import SwiftUI
import WebKit

@MainActor
final class RavadaPortalWindow: NSObject, NSWindowDelegate {
    static let shared = RavadaPortalWindow()
    private var window: NSWindow?
    private var model: RavadaPortalModel?

    func show() {
        let address = UserDefaults.standard.string(forKey: RavadaPortalConfiguration.urlKey) ?? ""
        let url = RavadaPortalConfiguration.portalURL(address)
        if window == nil || model?.portalURL != url {
            model?.stop()
            let model = url.map { RavadaPortalModel(portalURL: $0) }
            self.model = model
            let hosting = NSHostingController(rootView: RavadaPortalView(model: model))
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
        window = nil
    }

    func close() {
        model?.stop()
        window?.close()
    }

    func clearLogin() {
        let address = UserDefaults.standard.string(forKey: RavadaPortalConfiguration.urlKey) ?? ""
        guard let url = RavadaPortalConfiguration.portalURL(address) else { return }
        let store = RavadaPortalConfiguration.websiteDataStore(for: url)
        model?.stop()
        window?.close()
        // Reopening must use an empty store immediately, even while WebKit finishes
        // removing data from the old one asynchronously.
        _ = RavadaPortalConfiguration.websiteDataStore(for: url, replacing: true)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

}

private struct RavadaPortalView: View {
    let model: RavadaPortalModel?
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
