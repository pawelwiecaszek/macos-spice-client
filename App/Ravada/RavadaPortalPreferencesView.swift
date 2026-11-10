import SwiftUI

struct RavadaPortalPreferencesView: View {
    @Binding var preferences: RavadaPortalPreferences

    var body: some View {
        preference("Resize guest to window", selection: $preferences.resizeGuestWithWindow)
        preference("Retina resolution", selection: $preferences.useRetinaResolution)
        preference("Send ⌘ as Windows key", selection: $preferences.sendCommandKeyToGuest)
        preference("Share clipboard", selection: $preferences.shareClipboard)
        Text("Clipboard sharing lets the active VDI read text and images on your Mac clipboard.")
            .font(.caption).foregroundStyle(.secondary)
        preference("Play guest audio", selection: $preferences.playGuestAudio)
    }

    private func preference(_ title: LocalizedStringKey, selection: Binding<Bool?>) -> some View {
        Picker(title, selection: selection) {
            Text("Use General setting").tag(nil as Bool?)
            Text("On").tag(Optional(true))
            Text("Off").tag(Optional(false))
        }
    }
}
