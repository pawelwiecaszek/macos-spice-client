import Foundation
import VVFile

/// A Proxmox VE server (cluster node) the app can talk to over its REST API.
/// The API token *secret* is not part of this value: it lives in the Keychain.
public struct ProxmoxServer: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    /// `user@realm!tokenname`.
    public var tokenID: String
    /// SHA-256 of the server certificate the user explicitly chose to trust (hex), if any.
    public var pinnedCertificateSHA256: String?
    /// Cluster CA (`pve-root-ca`) learned from a `.vv` file of this host, if any.
    public var clusterCAPEM: String?

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 8006, tokenID: String,
                pinnedCertificateSHA256: String? = nil, clusterCAPEM: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.tokenID = tokenID
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
        self.clusterCAPEM = clusterCAPEM
    }

    /// `user@realm!name`: letters, digits and `-_.@!` only (it goes into an HTTP header).
    public static func isValidTokenID(_ text: String) -> Bool {
        let parts = text.split(separator: "!", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].contains("@"), !parts[1].isEmpty, text.count <= 256 else { return false }
        return text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.@!".unicodeScalars.contains($0)) }
    }

    /// Token secrets are UUIDs.
    public static func isValidSecret(_ text: String) -> Bool {
        UUID(uuidString: text) != nil
    }
}

/// A QEMU virtual machine as listed by `/cluster/resources`.
public struct ProxmoxVM: Sendable, Hashable, Identifiable {
    public var vmid: Int
    public var name: String
    public var node: String
    /// `running`, `stopped`, `paused`, …
    public var status: String
    public var id: String { "\(node)/\(vmid)" }
    public var isRunning: Bool { status == "running" }
    /// Paused or suspended (QMP status).
    public var isPaused: Bool { status == "paused" || status == "suspended" }

    public init(vmid: Int, name: String, node: String, status: String) {
        self.vmid = vmid
        self.name = name
        self.node = node
        self.status = status
    }
}

/// `POST /nodes/{node}/qemu/{vmid}/status/{action}`.
public enum ProxmoxPowerAction: String, Sendable, CaseIterable {
    case start, shutdown, reboot, reset, stop, suspend, resume

    /// Actions that cut the guest off without asking it (data loss risk): confirm first.
    public var isDestructive: Bool { self == .reset || self == .stop }
}

/// The VM a `.vv` file from Proxmox points at.
public struct ProxmoxVMRef: Sendable, Hashable {
    /// Host of the node's API (the `.vv` proxy host; the API listens on 8006).
    public var apiHost: String
    public var node: String
    public var vmid: Int

    public init(apiHost: String, node: String, vmid: Int) {
        self.apiHost = apiHost
        self.node = node
        self.vmid = vmid
    }

    /// Proxmox `.vv` hosts look like `pvespiceproxy:<ticket>:<vmid>:<node>::<…>` and the
    /// proxy is the node itself (`http://<node>:3128`).
    public init?(profile: ConnectionProfile) {
        guard let proxy = profile.proxy else { return nil }
        let fields = profile.host.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count >= 4, fields[0] == "pvespiceproxy", let vmid = Int(fields[2]), vmid > 0,
              !fields[3].isEmpty else { return nil }
        self.init(apiHost: proxy.host, node: String(fields[3]), vmid: vmid)
    }
}
