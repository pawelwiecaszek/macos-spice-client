import SwiftUI

struct MainWindowView: View {
    @Bindable var navigation: MainWindowController

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            Group {
                switch navigation.page {
                case .home:
                    WelcomeView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .portal:
                    RavadaPortalView(model: navigation.model, profileID: navigation.displayedProfile?.id)
                case .desktops:
                    if let store = navigation.desktopStore {
                        RavadaDesktopListView(store: store, openPortal: { navigation.showPortal(profileID: navigation.displayedProfile?.id) })
                    }
                case .portals:
                    RavadaSettingsView()
                        .frame(maxWidth: 800)
                        .frame(maxWidth: .infinity)
                case .proxmox:
                    VMListView(store: .shared)
                case .settings:
                    SettingsView(settings: .shared)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480, maxHeight: .infinity)
        .navigationTitle(pageTitle)
    }

    private var navigationBar: some View {
        HStack {
            if navigation.page != .home {
                Button("Connections", systemImage: "house") { navigation.showHome() }
                    .accessibilityIdentifier("showConnectionsHome")
            }
            if navigation.page != .portal {
                Button("Ravada Portal", systemImage: "globe") {
                    navigation.showPortal(profileID: navigation.displayedProfile?.id)
                }
                    .accessibilityIdentifier("returnToPortal")
            }
            if navigation.page == .portal {
                Button("My Desktops", systemImage: "desktopcomputer") { navigation.showDesktops() }
                    .accessibilityIdentifier("showRavadaDesktops")
            }
            if navigation.page != .portals {
                Button("Manage Portals", systemImage: "globe.badge.gearshape") { navigation.showPortals() }
                    .accessibilityIdentifier("showPortalProfiles")
            }
            Spacer()
            Button("Settings", systemImage: "gearshape") { navigation.showSettings() }
                .accessibilityIdentifier("showMainSettings")
        }
        .buttonStyle(.glass)
        .padding(12)
    }

    private var pageTitle: String {
        switch navigation.page {
        case .home: String(localized: "Connections")
        case .portal: String(localized: "Ravada Portal")
        case .portals: String(localized: "Saved Portals")
        case .desktops: String(localized: "My Desktops")
        case .proxmox: String(localized: "Virtual Machines")
        case .settings: String(localized: "Settings")
        }
    }
}
