import SpiceWire

/// Where and how to reach a SPICE server (transport-level view of a `.vv` profile).
public struct SpiceEndpoint: Sendable, Hashable {
    public struct Proxy: Sendable, Hashable {
        public var host: String
        public var port: UInt16
        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
    }

    public enum SecureChannels: Sendable, Hashable {
        case unspecified
        case all
        case some(Set<ChannelType>)
    }

    /// Server host, or an opaque proxy target (Proxmox) used verbatim in CONNECT.
    public var host: String
    public var port: UInt16?
    public var tlsPort: UInt16?
    public var proxy: Proxy?
    /// DER certificates used as the only trust anchors (from the `.vv` `ca`).
    public var trustAnchors: [[UInt8]]
    /// Expected server certificate subject (`host-subject`), already parsed.
    public var hostSubject: [X509.NameAttribute]?
    public var secureChannels: SecureChannels

    public init(host: String, port: UInt16? = nil, tlsPort: UInt16? = nil, proxy: Proxy? = nil,
                trustAnchors: [[UInt8]] = [], hostSubject: [X509.NameAttribute]? = nil,
                secureChannels: SecureChannels = .unspecified) {
        self.host = host
        self.port = port
        self.tlsPort = tlsPort
        self.proxy = proxy
        self.trustAnchors = trustAnchors
        self.hostSubject = hostSubject
        self.secureChannels = secureChannels
    }

    /// How to open one channel.
    public struct Route: Sendable, Hashable {
        public var port: UInt16
        public var useTLS: Bool
    }

    /// `true` when `secure-channels` demands TLS for `channel`.
    public func requiresTLS(_ channel: ChannelType) -> Bool {
        switch secureChannels {
        case .unspecified: false
        case .all: true
        case .some(let set): set.contains(channel)
        }
    }

    /// Chooses TLS vs plain for a channel.
    ///
    /// * only a TLS port → TLS;
    /// * only a plain port → plain, unless `secure-channels` requires TLS for this
    ///   channel: then the connection is refused rather than downgraded;
    /// * both ports → TLS, unless `secure-channels` is given and omits this channel
    ///   (then plain is used, as virt-viewer does).
    public func route(for channel: ChannelType) throws(TransportError) -> Route {
        switch (port, tlsPort) {
        case (nil, nil):
            throw .noRoute
        case (let plain?, nil):
            guard !requiresTLS(channel) else {
                throw .insecureConfiguration("\(channel) requires TLS but no TLS port is configured")
            }
            return Route(port: plain, useTLS: false)
        case (nil, let tls?):
            return Route(port: tls, useTLS: true)
        case (let plain?, let tls?):
            switch secureChannels {
            case .unspecified, .all:
                return Route(port: tls, useTLS: true)
            case .some(let set):
                return set.contains(channel) ? Route(port: tls, useTLS: true) : Route(port: plain, useTLS: false)
            }
        }
    }

    /// Fallback after `SPICE_LINK_ERR_NEED_SECURED` on a plain connection.
    public func secureRoute() -> Route? {
        tlsPort.map { Route(port: $0, useTLS: true) }
    }
}

/// Opens byte streams to an endpoint. Implemented with Network.framework on Apple
/// platforms; tests substitute in-memory streams.
public protocol StreamConnector: Sendable {
    func connect(to endpoint: SpiceEndpoint, route: SpiceEndpoint.Route) async throws -> any SpiceByteStream
}
