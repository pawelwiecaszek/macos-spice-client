import SwiftUI

/// Shared menu content for portal switching and the File menu.
struct RavadaPortalMenuContent: View {
    @Bindable private var store = RavadaPortalStore.shared
    var selectedID: UUID?

    var body: some View {
        if store.profiles.isEmpty {
            Text("No Saved Portals")
        } else {
            if !store.favorites.isEmpty {
                Section("Favorites") {
                    ForEach(store.favorites) { profile in portalButton(profile) }
                }
            }
            let others = store.profiles.filter { !$0.isFavorite }
            if !others.isEmpty {
                Section("Portals") {
                    ForEach(others) { profile in portalButton(profile) }
                }
            }
        }
    }

    private func portalButton(_ profile: RavadaPortalProfile) -> some View {
        Button(profile.name, systemImage: profile.id == (selectedID ?? store.selectedID) ? "checkmark" : "globe") {
            RavadaPortalWindow.shared.show(profileID: profile.id)
        }
    }
}
