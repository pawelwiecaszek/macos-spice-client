import SpiceKit
import SwiftUI

/// Settings › Proxmox: servers with API tokens (secrets in the Keychain).
struct ProxmoxSettingsView: View {
    @Bindable var store: ProxmoxStore
    @State private var editing: ProxmoxServer?
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                if store.servers.isEmpty {
                    Text("No servers yet.").foregroundStyle(.secondary)
                }
                ForEach(store.servers) { server in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(server.name)
                            Text("\(server.tokenID) · \(server.host):\(server.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit…") { editing = server }
                        Button(role: .destructive) { store.remove(server) } label: { Label("Remove \(server.name)", systemImage: "trash").labelStyle(.iconOnly) }
                            .help("Remove this server and delete its token from the Keychain")
                    }
                }
                Button("Add Server…") { adding = true }
            } header: {
                Text("Proxmox VE servers")
            } footer: {
                Text("Used for Start, Shut Down, Reboot and the Virtual Machines window. Create an API token in Proxmox (Datacenter › Permissions › API Tokens) with VM.Audit, VM.PowerMgmt and VM.Console on your VMs. The secret is stored in your Keychain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $adding) {
            ServerEditor(store: store, server: ProxmoxServer(name: "", host: store.pendingHost ?? "", tokenID: ""), isNew: true)
                .onDisappear { store.pendingHost = nil }  // also on Cancel
        }
        .sheet(item: $editing) { server in
            ServerEditor(store: store, server: server, isNew: false)
        }
        .onChange(of: store.pendingHost, initial: true) { _, host in
            if let host, store.server(forHost: host) == nil { adding = true }
        }
    }
}

/// Add/edit sheet. Saving tests the connection; an untrusted certificate can be pinned
/// after the user compares its fingerprint.
struct ServerEditor: View {
    let store: ProxmoxStore
    @State var server: ProxmoxServer
    let isNew: Bool
    @State private var secret = ""
    @State private var portText = ""
    @State private var status: String?
    @State private var untrustedFingerprint: String?
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Name", text: $server.name, prompt: Text("Office cluster"))
            TextField("Host", text: $server.host, prompt: Text("pve1.example.com"))
            TextField("Port", text: $portText, prompt: Text("8006"))
            TextField("Token ID", text: $server.tokenID, prompt: Text("user@pve!spice"))
            SecureField(isNew ? "Token secret" : "Token secret (leave empty to keep)", text: $secret,
                        prompt: Text("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
            if let untrustedFingerprint {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The server’s certificate isn’t trusted by macOS or by a Proxmox CA this app has seen.")
                    Text("SHA-256: \(ProxmoxError.formatted(untrustedFingerprint))")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("Compare it with Proxmox › node › System › Certificates (pve-ssl.pem) before trusting it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Trust This Certificate") {
                        server.pinnedCertificateSHA256 = untrustedFingerprint
                        self.untrustedFingerprint = nil
                        test()
                    }
                }
            }
            if let status {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") { test() }.disabled(working || !inputValid)
            }
        }
        .onAppear { portText = String(server.port) }
    }

    private var inputValid: Bool {
        !server.host.isEmpty && ProxmoxServer.isValidTokenID(server.tokenID) && Int(portText) != nil
            && (secret.isEmpty ? !isNew : ProxmoxServer.isValidSecret(secret))
    }

    /// Lists VMs with the entered settings; saves only when that works.
    private func test() {
        guard let port = Int(portText) else { return }
        server.port = port
        if server.name.isEmpty { server.name = server.host }
        let candidate = server
        let enteredSecret = secret.isEmpty ? ProxmoxKeychain.secret(for: server.id) ?? "" : secret
        working = true
        status = String(localized: "Connecting…")
        Task {
            defer { working = false }
            do {
                var withCA = candidate
                if withCA.clusterCAPEM == nil, let known = store.server(forHost: candidate.host)?.clusterCAPEM {
                    withCA.clusterCAPEM = known
                }
                let client = try ProxmoxClient(server: withCA, secret: enteredSecret)
                let vms = try await client.virtualMachines()
                try store.save(withCA, secret: secret.isEmpty ? nil : secret)
                store.pendingHost = nil
                status = String(localized: "Connected: \(vms.count) virtual machines visible.")
                dismiss()
            } catch ProxmoxError.untrustedCertificate(let fingerprint) {
                untrustedFingerprint = fingerprint
                status = nil
            } catch {
                status = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
