import SpiceTransport
import SpiceWire

/// Connects and links channels for one session.
public struct ChannelOpener: Sendable {
    public let endpoint: SpiceEndpoint
    public let connector: any StreamConnector
    public let encryptor: any TicketEncryptor
    /// Returns the ticket bytes, or `nil` once wiped (then an empty ticket is sent).
    public let ticket: @Sendable () -> [UInt8]?

    private let log = ChannelLogger(category: "link")
    /// Upper bound for connect + link + authentication of one channel.
    public var linkTimeout: Duration = .seconds(20)

    public init(endpoint: SpiceEndpoint, connector: any StreamConnector, encryptor: any TicketEncryptor,
                ticket: @escaping @Sendable () -> [UInt8]?) {
        self.endpoint = endpoint
        self.connector = connector
        self.encryptor = encryptor
        self.ticket = ticket
    }

    /// Opens `type`/`id` with `connectionID` (0 for main, then the session id).
    public func open(type: ChannelType, id: UInt8, connectionID: UInt32,
                     channelCaps: CapabilitySet) async throws -> ChannelConnection {
        let route = try endpoint.route(for: type)
        do {
            return try await open(type: type, id: id, connectionID: connectionID, channelCaps: channelCaps, route: route)
        } catch TransportError.linkRejected(.needSecured) where !route.useTLS {
            guard let secure = endpoint.secureRoute() else { throw TransportError.linkRejected(.needSecured) }
            log.info("\(type) requires TLS; retrying on the TLS port")
            return try await open(type: type, id: id, connectionID: connectionID, channelCaps: channelCaps, route: secure)
        }
    }

    private func open(type: ChannelType, id: UInt8, connectionID: UInt32, channelCaps: CapabilitySet,
                      route: SpiceEndpoint.Route) async throws -> ChannelConnection {
        let stream = try await connector.connect(to: endpoint, route: route)
        do {
            let message = LinkMessage(connectionID: connectionID, channelType: type, channelID: id,
                                      commonCaps: ChannelLinker.clientCommonCaps, channelCaps: channelCaps)
            let ticketBytes = ticket() ?? []
            let encryptor = self.encryptor
            let timeout = linkTimeout
            // A silent server must not stall the session: race the handshake against a timer.
            let linked = try await withThrowingTaskGroup(of: LinkedChannel?.self) { group in
                group.addTask {
                    try await ChannelLinker.link(stream: stream, message: message, ticket: ticketBytes, encryptor: encryptor)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let result = first else {
                    await stream.close()  // unblocks the pending receive
                    throw TransportError.timedOut
                }
                return result
            }
            log.debug("\(type):\(id) linked (tls=\(route.useTLS))")
            return ChannelConnection(type: type, id: id, stream: stream, serverCaps: linked.serverChannelCaps)
        } catch {
            await stream.close()
            throw error
        }
    }
}
