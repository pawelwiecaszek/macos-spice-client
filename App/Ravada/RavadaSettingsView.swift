import SwiftUI

struct RavadaSettingsView: View {
    @AppStorage(RavadaPortalConfiguration.urlKey) private var address = ""

    var body: some View {
        Form {
            Section("Ravada Portal") {
                TextField("Portal URL", text: $address, prompt: Text("https://vdi.example.com/"))
                    .textContentType(.URL)
                    .accessibilityLabel("Portal URL")
                    .accessibilityIdentifier("ravadaPortalURLField")
                if !address.isEmpty, RavadaPortalConfiguration.portalURL(address) == nil {
                    Text("Enter an HTTPS address without a username, password, or fragment.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Sign in and choose a machine in the portal. SPICE connections open in the native viewer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Ravada Portal…") { RavadaPortalWindow.shared.show() }
            }
            Section("Login") {
                Text("Each portal keeps its own browser login. Passwords are entered on the portal’s sign-in page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear Portal Login", role: .destructive) {
                    RavadaPortalWindow.shared.clearLogin()
                }
                .disabled(RavadaPortalConfiguration.portalURL(address) == nil)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
