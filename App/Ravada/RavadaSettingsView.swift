import SwiftUI

struct RavadaSettingsView: View {
    @Bindable private var store = RavadaPortalStore.shared
    @State private var draft = RavadaPortalProfile(name: "", address: "")
    @State private var editorID: UUID?
    @State private var saveError: String?
    @State private var confirmingRemoval = false

    var body: some View {
        Form {
            Section("Saved Portals") {
                if let error = store.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                Picker("Portal", selection: Binding(
                    get: { editorID },
                    set: { id in
                        guard let id else { newProfile(); return }
                        do { try store.select(id); loadSelected() }
                        catch { saveError = error.localizedDescription }
                    }
                )) {
                    Text("New Portal").tag(nil as UUID?)
                    ForEach(store.profiles) { profile in
                        Text(profile.isFavorite ? "★ \(profile.name)" : profile.name)
                            .tag(Optional(profile.id))
                    }
                }
                .accessibilityIdentifier("ravadaSavedPortalPicker")
                Button("New Portal") { newProfile() }
                    .disabled(!store.canModify || store.profiles.count >= RavadaPortalStore.maxProfiles)
                    .accessibilityIdentifier("newRavadaPortal")
            }
            Section("Portal Details") {
                TextField("Name", text: $draft.name, prompt: Text("Work desktops"))
                    .accessibilityLabel("Portal Name")
                    .accessibilityIdentifier("ravadaPortalNameField")
                TextField("Portal URL", text: $draft.address, prompt: Text("https://vdi.example.com/"))
                    .textContentType(.URL)
                    .accessibilityLabel("Portal URL")
                    .accessibilityIdentifier("ravadaPortalURLField")
                if !draft.address.isEmpty, !validAddress {
                    Text("Enter an HTTPS address without credentials, a query, or a fragment.")
                        .font(.caption).foregroundStyle(.red)
                }
                Toggle("Favorite portal", isOn: $draft.isFavorite)
                    .accessibilityIdentifier("ravadaPortalFavorite")
                Text("Favorites appear on the welcome screen. Changes apply when you save or open the portal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!store.canModify)
            Section("Session Preferences") {
                RavadaPortalPreferencesView(preferences: $draft.preferences)
                Text("Applies to new VDI sessions from this portal. General settings and running sessions are unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!store.canModify)
            Section {
                if let saveError { Text(saveError).foregroundStyle(.red) }
                HStack {
                    Button("Save Portal") { _ = saveProfile() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("saveRavadaPortal")
                    Button("Open Ravada Portal…") {
                        if let profile = saveProfile() { MainWindowController.shared.showPortal(profileID: profile.id) }
                    }
                    .disabled(!canSave)
                }
                if editorID != nil {
                    Button("Remove Saved Portal…", role: .destructive) { confirmingRemoval = true }
                        .disabled(!store.canModify)
                        .accessibilityIdentifier("removeRavadaPortal")
                    Button("Clear Portal Login", role: .destructive) {
                        guard let editorID else { return }
                        do {
                            try MainWindowController.shared.clearLogin(profileID: editorID)
                            loadSelected()
                        } catch { saveError = error.localizedDescription }
                    }
                    .disabled(!store.canModify)
                }
                Text("Each saved portal has its own browser login. Clear Portal Login removes only that profile’s browser data; it does not shut down a running desktop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minHeight: 620)
        .onAppear { loadSelected() }
        .confirmationDialog("Remove this saved portal and its browser login?", isPresented: $confirmingRemoval) {
            Button("Remove Portal", role: .destructive) {
                guard let editorID else { return }
                do {
                    if let removed = try store.remove(editorID) { MainWindowController.shared.removed(removed) }
                    loadSelected()
                } catch { saveError = error.localizedDescription }
            }
        } message: {
            Text("Other saved portals and running VDI sessions are unchanged.")
        }
    }

    private var validAddress: Bool {
        guard let url = RavadaPortalConfiguration.portalURL(draft.address),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.query == nil
    }

    private var canSave: Bool {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.canModify && !name.isEmpty && name.count <= 80 && validAddress
    }

    private func newProfile() {
        editorID = nil
        draft = RavadaPortalProfile(name: "", address: "")
        saveError = nil
    }

    private func loadSelected() {
        guard let profile = store.selectedProfile else { newProfile(); return }
        draft = profile
        editorID = profile.id
        saveError = nil
    }

    private func saveProfile() -> RavadaPortalProfile? {
        guard canSave else { return nil }
        do {
            let saved: RavadaPortalProfile
            if editorID != nil {
                let old = store.profiles.first { $0.id == editorID }
                saved = try store.update(draft)
                if let old { MainWindowController.shared.updated(from: old, to: saved) }
            } else {
                saved = try store.add(name: draft.name, address: draft.address,
                                      isFavorite: draft.isFavorite, preferences: draft.preferences)
            }
            try store.select(saved.id)
            draft = saved
            editorID = saved.id
            saveError = nil
            return saved
        } catch {
            saveError = error.localizedDescription
            return nil
        }
    }
}
