#if canImport(Network)
import Foundation
import Network
import os
import Security
import SpiceWire

private let log = Logger(subsystem: "com.pawelwiecaszek.spiceclient", category: "transport")

/// Network.framework implementation of `StreamConnector`.
///
/// * TLS trust: the `.vv` CA certificates are the *only* anchors when present; the
///   `host-subject` is then enforced instead of the hostname. There is deliberately no
///   way to skip verification.
/// * Proxy: an `HTTPConnectFramer` sits between TCP and TLS and performs the
///   `CONNECT host:port` exchange, so TLS runs end-to-end through the tunnel.
public struct NetworkConnector: StreamConnector {
    public var connectTimeout: Duration

    public init(connectTimeout: Duration = .seconds(15)) {
        self.connectTimeout = connectTimeout
    }

    public func connect(to endpoint: SpiceEndpoint, route: SpiceEndpoint.Route) async throws -> any SpiceByteStream {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Notice dead links (sleep/wake, Wi-Fi changes, NAT timeouts) within ~30 s so the
        // app can reconnect, instead of the system default of hours.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionDropTime = 30
        tcp.connectionTimeout = Int(connectTimeout.components.seconds)

        let parameters: NWParameters
        if route.useTLS {
            parameters = NWParameters(tls: makeTLSOptions(for: endpoint), tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }

        let nwEndpoint: NWEndpoint
        var proxyTarget: String?
        if let proxy = endpoint.proxy {
            // TCP goes to the proxy; the framer asks it to CONNECT to host:port.
            let framer = NWProtocolFramer.Options(definition: HTTPConnectFramer.definition)
            // applicationProtocols is ordered top → bottom; TLS (if any) stays on top.
            parameters.defaultProtocolStack.applicationProtocols.append(framer)
            guard let port = NWEndpoint.Port(rawValue: proxy.port) else {
                throw TransportError.connectionFailed("invalid proxy port")
            }
            nwEndpoint = .hostPort(host: NWEndpoint.Host(proxy.host), port: port)
            proxyTarget = "\(endpoint.host):\(route.port)"
        } else {
            guard let port = NWEndpoint.Port(rawValue: route.port) else {
                throw TransportError.connectionFailed("invalid port")
            }
            nwEndpoint = .hostPort(host: NWEndpoint.Host(endpoint.host), port: port)
        }

        let connection = NWConnection(to: nwEndpoint, using: parameters)
        let stream = NWByteStream(connection: connection)
        if let proxyTarget {
            // The framer cannot receive per-connection options from Swift, so proxied
            // handshakes are serialized and the target is handed over through a slot.
            try await ProxyTargetSlot.shared.withTarget(proxyTarget) {
                do {
                    try await stream.start(timeout: connectTimeout)
                } catch {
                    // Surface the proxy's HTTP status instead of a generic socket error.
                    if let status = ProxyTargetSlot.lastStatus.withLock({ $0 }), !(200..<300).contains(status) {
                        throw TransportError.proxyRefused(status: status)
                    }
                    if ProxyTargetSlot.lastStatus.withLock({ $0 }) == nil, ProxyTargetSlot.sawResponse.withLock({ $0 }) {
                        throw TransportError.proxyProtocolError
                    }
                    throw error
                }
            }
        } else {
            try await stream.start(timeout: connectTimeout)
        }
        log.debug("connected route tls=\(route.useTLS, privacy: .public) proxied=\(proxyTarget != nil, privacy: .public)")
        return stream
    }

    private func makeTLSOptions(for endpoint: SpiceEndpoint) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        let anchors: [SecCertificate] = endpoint.trustAnchors.compactMap {
            SecCertificateCreateWithData(nil, Data($0) as CFData)
        }
        // A supplied CA that Security.framework can't load must not fall back to system trust.
        let anchorsUsable = anchors.count == endpoint.trustAnchors.count
        let expectedSubject = endpoint.hostSubject
        // `host-subject` replaces the hostname check (Proxmox hosts are opaque tokens, not
        // DNS names); without it the hostname is verified, as spice-gtk does.
        let hostname: String? = expectedSubject == nil ? endpoint.host : nil
        let verifyQueue = DispatchQueue(label: "com.pawelwiecaszek.spiceclient.tls-verify")
        sec_protocol_options_set_verify_block(security, { _, trustRef, complete in
            guard anchorsUsable else {
                log.error("TLS verification failed: unusable CA certificate in the connection file")
                complete(false)
                return
            }
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            let outcome = TLSVerifier.evaluate(trust: trust, anchors: anchors, hostname: hostname,
                                               expectedSubject: expectedSubject)
            if case .failure(let reason) = outcome {
                // The reason can name the certificate's subject or host: keep it private.
                log.error("TLS verification failed: \(reason, privacy: .private)")
                complete(false)
            } else {
                complete(true)
            }
        }, verifyQueue)
        return options
    }
}

/// Certificate checks shared by the verify block.
enum TLSVerifier {
    enum Outcome { case success, failure(String) }

    static func evaluate(trust: SecTrust, anchors: [SecCertificate], hostname: String?,
                         expectedSubject: [X509.NameAttribute]?) -> Outcome {
        // Always a TLS-server policy (EKU, key usage); the hostname is only omitted when
        // `host-subject` replaces it with an explicit subject match below.
        let policy = SecPolicyCreateSSL(true, hostname as CFString?)
        SecTrustSetPolicies(trust, policy)
        if !anchors.isEmpty {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            return .failure(error.map { CFErrorCopyDescription($0) as String } ?? "untrusted certificate")
        }
        if let expectedSubject {
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
                return .failure("no certificate chain")
            }
            let der = Array(SecCertificateCopyData(leaf) as Data)
            guard let subject = X509.subject(ofCertificate: der) else { return .failure("unreadable subject") }
            guard HostSubject.matches(expected: expectedSubject, actual: subject) else {
                return .failure("certificate subject does not match host-subject")
            }
        }
        return .success
    }
}

/// Serializes proxied connection setup and hands the CONNECT target to the framer.
actor ProxyTargetSlot {
    static let shared = ProxyTargetSlot()
    /// Read by `HTTPConnectFramer.start` (on Network.framework's queue).
    nonisolated static let current = OSAllocatedUnfairLock<String?>(initialState: nil)
    /// HTTP status of the last CONNECT response (written by the framer).
    nonisolated static let lastStatus = OSAllocatedUnfairLock<Int?>(initialState: nil)
    nonisolated static let sawResponse = OSAllocatedUnfairLock<Bool>(initialState: false)

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withTarget<T: Sendable>(_ target: String, _ body: @Sendable () async throws -> T) async throws -> T {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        Self.current.withLock { $0 = target }
        Self.lastStatus.withLock { $0 = nil }
        Self.sawResponse.withLock { $0 = false }
        defer {
            Self.current.withLock { $0 = nil }
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

/// HTTP CONNECT tunnel as a Network.framework protocol framer.
final class HTTPConnectFramer: NWProtocolFramerImplementation {
    static let label = "SpiceHTTPConnect"
    static let definition = NWProtocolFramer.Definition(implementation: HTTPConnectFramer.self)

    private var response: [UInt8] = []
    private var established = false

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        guard let target = ProxyTargetSlot.current.withLock({ $0 }),
              let request = HTTPConnect.request(target: target) else {
            framer.markFailed(error: .posix(.EINVAL))
            return .willMarkReady
        }
        framer.writeOutput(data: Data(request))
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while !established {
            var headerComplete = false
            let parsed = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 8192) { buffer, _ in
                guard let buffer, !buffer.isEmpty else { return 0 }
                // Consume byte by byte up to the end of the header, leaving TLS bytes untouched.
                var consumed = 0
                for byte in buffer {
                    self.response.append(byte)
                    consumed += 1
                    if HTTPConnect.headerEnd(in: self.response) != nil {
                        headerComplete = true
                        break
                    }
                }
                return consumed
            }
            if !parsed { return 0 }
            if response.count > 16 * 1024 {
                framer.markFailed(error: .posix(.EPROTO))
                return 0
            }
            if headerComplete {
                let status = HTTPConnect.statusCode(ofResponse: response)
                ProxyTargetSlot.sawResponse.withLock { $0 = true }
                ProxyTargetSlot.lastStatus.withLock { $0 = status }
                let statusLine = String(decoding: response.prefix { $0 != 13 }, as: UTF8.self)
                guard let status, (200..<300).contains(status) else {
                    let code = status ?? 0
                    let reason = String(statusLine.prefix(120).map { $0.isASCII && !$0.isNewline ? $0 : " " })
                    log.error("proxy refused CONNECT: HTTP \(code, privacy: .public) \(reason, privacy: .private)")
                    framer.markFailed(error: .posix(.ECONNREFUSED))
                    return 0
                }
                established = true
                framer.markReady()
                framer.passThroughInput()
                framer.passThroughOutput()
                return 0
            }
        }
        return 0
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message,
                      messageLength: Int, isComplete: Bool) {
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            framer.markFailed(error: .posix(.EIO))
        }
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}

/// `SpiceByteStream` over an `NWConnection`, with an internal read buffer.
actor NWByteStream: SpiceByteStream {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.pawelwiecaszek.spiceclient.connection")
    private var buffer: [UInt8] = []
    private var readOffset = 0
    private var finished = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start(timeout: Duration) async throws {
        let connection = self.connection
        let gate = OnceGate()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if gate.claim() { continuation.resume() }
                        case .failed(let error):
                            if gate.claim() { continuation.resume(throwing: Self.map(error)) }
                        case .waiting(let error):
                            // Refused / unreachable: report instead of waiting forever.
                            if gate.claim() { continuation.resume(throwing: Self.map(error)) }
                        case .cancelled:
                            if gate.claim() { continuation.resume(throwing: TransportError.closed) }
                        default:
                            break
                        }
                    }
                    connection.start(queue: self.queue)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TransportError.timedOut
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                connection.cancel()
                throw error
            }
        }
    }

    nonisolated static func map(_ error: NWError) -> TransportError {
        switch error {
        case .tls(let status):
            .tlsVerificationFailed("OSStatus \(status)")
        case .posix(let code) where code == .ECONNREFUSED:
            .connectionFailed("connection refused")
        default:
            .connectionFailed(error.localizedDescription)
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        let connection = self.connection
        // Cancelling the connection completes any pending callback with an error.
        try await withTaskCancellationHandler {
            try await sendNow(bytes, on: connection)
        } onCancel: {
            connection.cancel()
        }
    }

    private func sendNow(_ bytes: [UInt8], on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: Self.map(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive(exactly count: Int) async throws -> [UInt8] {
        while buffer.count - readOffset < count {
            if finished { throw TransportError.closed }
            try await fill(minimum: count - (buffer.count - readOffset))
        }
        let result = Array(buffer[readOffset..<(readOffset + count)])
        readOffset += count
        if readOffset > 1 << 20 || readOffset == buffer.count {
            buffer.removeFirst(readOffset)
            readOffset = 0
        }
        return result
    }

    private func fill(minimum: Int) async throws {
        let connection = self.connection
        let maximum = max(minimum, 256 * 1024)
        let (data, complete): (Data?, Bool) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: Self.map(error))
                    } else {
                        continuation.resume(returning: (data, isComplete))
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
        if let data { buffer.append(contentsOf: data) }
        if complete { finished = true }
        if data == nil && !complete { finished = true }
    }

    func close() async {
        connection.cancel()
    }
}

/// Lets exactly one caller win (for resuming a continuation once).
final class OnceGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    func claim() -> Bool {
        state.withLock { claimed in
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
#endif
