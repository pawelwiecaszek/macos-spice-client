import USBRedirWire

/// SPICE channel names as used by the `.vv` `secure-channels` key.
public enum ChannelName: String, Sendable, Hashable, CaseIterable {
    case main, display, inputs, cursor, playback, record, smartcard, usbredir, port, webdav
}

/// Which channels must use TLS.
public enum SecureChannels: Sendable, Hashable {
    /// Key absent: no per-channel requirement.
    case unspecified
    case all
    case some(Set<ChannelName>)

    public func requiresTLS(_ channel: ChannelName) -> Bool {
        switch self {
        case .unspecified: false
        case .all: true
        case .some(let set): set.contains(channel)
        }
    }
}

/// An HTTP CONNECT proxy from the `.vv` `proxy` key.
public struct ProxyEndpoint: Sendable, Hashable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// Everything needed to open a SPICE session, parsed from a virt-viewer `.vv` file.
public struct ConnectionProfile: Sendable {
    /// Host to connect to. For Proxmox this is an opaque proxy target such as
    /// `pvespiceproxy:6527b3e1:101:pve1::abc…` and must be passed verbatim in CONNECT.
    public var host: String
    public var port: UInt16?
    public var tlsPort: UInt16?
    /// One-time ticket. Memory only; never logged or persisted.
    public var password: SecretTicket?
    public var proxy: ProxyEndpoint?
    /// PEM certificate(s) to use as the *sole* trust anchors, `\n` already unescaped.
    public var caPEM: String?
    /// Expected server certificate subject, e.g. `OU=…,O=…,CN=pve1.example.com`.
    public var hostSubject: String?
    public var secureChannels: SecureChannels = .unspecified
    public var title: String?
    public var fullscreen = false
    public var deleteThisFile = false

    public var toggleFullscreenHotkey: Hotkey?
    public var releaseCursorHotkey: Hotkey?
    public var secureAttentionHotkey: Hotkey?

    /// `nil` = key absent (enabled if the server offers usbredir channels).
    public var enableUSBRedirection: Bool?
    public var enableUSBAutoshare = false
    public var usbFilter: USBFilter?
    /// `nil` = key absent (offered if the server has a smartcard channel); `false` hides it.
    public var enableSmartcard: Bool?

    // Parsed and kept, but unused in v1.
    public var colorDepth: Int?
    public var disableEffects: [String] = []
    public var versions: String?
    public var newerVersionURL: String?

    /// Keys from `[virt-viewer]` that this parser does not model, kept for diagnostics.
    /// Never contains `password`.
    public var unknownKeys: [String: String] = [:]

    public init(host: String) {
        self.host = host
    }

    /// Display title for the session window.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "SPICE"
    }
}

extension ConnectionProfile: CustomStringConvertible {
    /// Redacted summary safe for logs (no ticket, no CA material).
    public var description: String {
        "ConnectionProfile(port: \(port.map(String.init) ?? "-"), tlsPort: \(tlsPort.map(String.init) ?? "-"), "
            + "proxy: \(proxy != nil), ca: \(caPEM != nil), hostSubject: \(hostSubject != nil), "
            + "ticket: \(password != nil))"
    }
}
