import AppKit
import SwiftUI
import WebKit

struct RavadaPortalView: View {
    let model: RavadaPortalModel?
    let profileID: UUID?

    var body: some View {
        Group {
            if let model {
                BrowserContent(model: model)
                    .id(ObjectIdentifier(model))
            } else {
                ContentUnavailableView {
                    Label("Set Up Ravada", systemImage: "globe")
                } description: {
                    Text("Save a Ravada portal to start connecting.")
                } actions: {
                    Button("Manage Portals…") { MainWindowController.shared.showPortals() }
                        .accessibilityIdentifier("manageRavadaPortals")
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
