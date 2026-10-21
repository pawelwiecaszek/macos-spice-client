import AppKit
import Observation
import SpiceKit
import os

/// Proxmox servers the user added (API tokens in the Keychain) and the actions built on
/// them: power control, VM list, connecting without a downloaded `.vv`.
@MainActor
@Observable
final class ProxmoxStore {
    static let shared = ProxmoxStore()

    private(set) var servers: [ProxmoxServer] = []
    /// Host to prefill when the user is sent to Settings from a session's Power menu.
    var pendingHost: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var learnedCAs: [String: String] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.pawelwiecaszek.spiceclient", category: "proxmox")

    private enum Keys {
        static let servers = "proxmoxServers"
        static let clusterCAs = "proxmoxClusterCAs"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.servers),
           let decoded = try? JSONDecoder().decode([ProxmoxServer].self, from: data) {
            servers = decoded
        }
        learnedCAs = defaults.dictionary(forKey: Keys.clusterCAs) as? [String: String] ?? [:]
    }

    // MARK: Servers

    func server(forHost host: String) -> ProxmoxServer? {
        servers.first { $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }

    /// Adds or replaces a server; `secret` (when given) goes to the Keychain.
    func save(_ server: ProxmoxServer, secret: String?) throws {
        var server = server
        if server.clusterCAPEM == nil { server.clusterCAPEM = learnedCAs[server.host.lowercased()] }
        if let secret { try ProxmoxKeychain.save(secret: secret, for: server.id) }
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        persist()
    }

    func remove(_ server: ProxmoxServer) {
        ProxmoxKeychain.delete(for: server.id)
        servers.removeAll { $0.id == server.id }
        persist()
    }

    func client(for server: ProxmoxServer) throws -> ProxmoxClient {
        guard let secret = ProxmoxKeychain.secret(for: server.id) else {
            throw ProxmoxError.invalidConfiguration(String(localized: "no API token secret saved"))
        }
        return try ProxmoxClient(server: server, secret: secret)
    }

    /// Remembers the cluster CA from a `.vv` that was fetched over an already verified API
    /// connection (never from a downloaded file: that could plant a CA for the API host).
    private func learn(from profile: ConnectionProfile) {
        guard let ref = ProxmoxVMRef(profile: profile), let ca = profile.caPEM else { return }
        let host = ref.apiHost.lowercased()
        guard learnedCAs[host] != ca else { return }
        learnedCAs[host] = ca
        defaults.set(learnedCAs, forKey: Keys.clusterCAs)
        if var server = server(forHost: host), server.clusterCAPEM != ca {
            server.clusterCAPEM = ca
            try? save(server, secret: nil)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) { defaults.set(data, forKey: Keys.servers) }
    }

    // MARK: Actions

    /// Starts the VM if needed, fetches a fresh SPICE connection file and opens a session.
    func connect(to vm: ProxmoxVM, on server: ProxmoxServer) async throws {
        let client = try client(for: server)
        if !vm.isRunning {
            let wake: ProxmoxPowerAction = vm.isPaused ? .resume : .start
            try await client.perform(wake, node: vm.node, vmid: vm.vmid)
            try await waitUntilRunning(client, node: vm.node, vmid: vm.vmid)
        }
        let profile = try await connectionProfile(client, node: vm.node, vmid: vm.vmid)
        SessionWindowManager.shared.openSession(profile)
    }

    /// A fresh connection (new one-time ticket) for a VM a session was showing, used to
    /// reconnect (M8). Fails with `.notRunning` when the VM is off or paused, so the session
    /// stops retrying and offers to start it instead.
    func reconnectProfile(for ref: ProxmoxVMRef) async throws -> ConnectionProfile {
        guard let server = server(forHost: ref.apiHost) else { throw ReconnectError.noAPIAccess }
        let client = try client(for: server)
        let status = try await client.status(node: ref.node, vmid: ref.vmid)
        guard status == "running" else { throw ReconnectError.notRunning(status) }
        return try await connectionProfile(client, node: ref.node, vmid: ref.vmid)
    }

    enum ReconnectError: Error, Equatable {
        case noAPIAccess
        case notRunning(String)
    }

    private func connectionProfile(_ client: ProxmoxClient, node: String, vmid: Int) async throws -> ConnectionProfile {
        let text = try await client.spiceConnectionFile(node: node, vmid: vmid)
        let file = try VVFileParser.parse(text)
        learn(from: file.profile)
        return file.profile
    }

    func perform(_ action: ProxmoxPowerAction, on ref: ProxmoxVMRef) async throws {
        guard let server = server(forHost: ref.apiHost) else { throw ProxmoxError.invalidConfiguration("no server") }
        try await client(for: server).perform(action, node: ref.node, vmid: ref.vmid)
    }

    private func waitUntilRunning(_ client: ProxmoxClient, node: String, vmid: Int) async throws {
        for _ in 0..<60 {
            if try await client.status(node: node, vmid: vmid) == "running" { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw ProxmoxError.http(status: 0, message: String(localized: "the VM didn’t start within a minute"))
    }

    /// Asks before actions that cut the guest off.
    static func confirm(_ action: ProxmoxPowerAction, vmName: String) -> Bool {
        guard action.isDestructive else { return true }
        let alert = NSAlert()
        alert.messageText = action == .reset
            ? String(localized: "Reset “\(vmName)”?")
            : String(localized: "Stop “\(vmName)”?")
        alert.informativeText = String(localized: "This is like pulling the power cord: unsaved work in the virtual machine is lost. Use Shut Down or Reboot to let the guest close cleanly.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: action == .reset ? String(localized: "Reset") : String(localized: "Stop"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension ProxmoxPowerAction {
    var title: String {
        switch self {
        case .start: String(localized: "Start")
        case .shutdown: String(localized: "Shut Down")
        case .reboot: String(localized: "Reboot")
        case .reset: String(localized: "Reset…")
        case .stop: String(localized: "Stop…")
        case .suspend: String(localized: "Pause")
        case .resume: String(localized: "Resume")
        }
    }

    var symbol: String {
        switch self {
        case .start, .resume: "play.fill"
        case .shutdown: "power"
        case .reboot: "arrow.clockwise"
        case .reset: "arrow.counterclockwise.circle"
        case .stop: "stop.fill"
        case .suspend: "pause.fill"
        }
    }
}
