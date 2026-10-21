#if canImport(Security)
import CryptoKit
import Foundation
import Security
import Synchronization
import SpiceTransport
import VVFile

public enum ProxmoxError: Error, Equatable, Sendable, LocalizedError {
    /// The certificate isn't trusted by macOS or the cluster CA; the user may pin it.
    case untrustedCertificate(sha256: String)
    case unauthorized
    case forbidden(String)
    case http(status: Int, message: String)
    case invalidResponse
    case invalidConfiguration(String)
    case transport(String)
    /// The VM's QEMU didn't answer Proxmox in time (`qmp command … got timeout`).
    case qemuNotResponding(vmid: Int)

    public var errorDescription: String? {
        switch self {
        case .untrustedCertificate(let fingerprint):
            "The server’s certificate isn’t trusted (SHA-256 \(ProxmoxError.formatted(fingerprint)))."
        case .unauthorized:
            "Proxmox rejected the API token. Check the token ID and secret."
        case .forbidden(let message):
            "The API token isn’t allowed to do this (\(message)). It needs VM.Audit, VM.PowerMgmt and VM.Console on the VM."
        case .http(let status, let message):
            "Proxmox returned HTTP \(status)\(message.isEmpty ? "" : ": \(message)")."
        case .invalidResponse:
            "Proxmox sent an unexpected response."
        case .invalidConfiguration(let reason):
            "The Proxmox server settings are invalid (\(reason))."
        case .transport(let reason):
            "Couldn’t reach the Proxmox server (\(reason))."
        case .qemuNotResponding(let vmid):
            "VM \(vmid) didn’t answer Proxmox in time when asked for its SPICE details. Make sure its "
                + "Display is set to SPICE and it isn’t busy with a backup or snapshot, then try again."
        }
    }

    /// `AB:CD:…` for display.
    public static func formatted(_ hex: String) -> String {
        let characters = Array(hex.uppercased())
        return stride(from: 0, to: characters.count, by: 2).map {
            String(characters[$0..<min($0 + 2, characters.count)])
        }.joined(separator: ":")
    }
}

/// Minimal Proxmox VE REST client (API token auth) for listing VMs, power actions and
/// SPICE connection files.
///
/// TLS: the certificate must validate against macOS trust or the cluster CA learned from a
/// `.vv` file (hostname checked), or match a fingerprint the user explicitly pinned. There
/// is no way to skip verification.
public final class ProxmoxClient: Sendable {
    public let server: ProxmoxServer
    private let authorization: String
    private let session: URLSession
    private let trust: TrustDelegate

    public init(server: ProxmoxServer, secret: String) throws(ProxmoxError) {
        guard HTTPConnect.isSafeTarget(server.host), (1...65535).contains(server.port) else {
            throw .invalidConfiguration("host")
        }
        guard ProxmoxServer.isValidTokenID(server.tokenID), ProxmoxServer.isValidSecret(secret) else {
            throw .invalidConfiguration("token")
        }
        self.server = server
        authorization = "PVEAPIToken=\(server.tokenID)=\(secret)"
        let anchors = server.clusterCAPEM.map(PEM.certificates(in:))?.compactMap {
            SecCertificateCreateWithData(nil, Data($0) as CFData)
        } ?? []
        trust = TrustDelegate(host: server.host, anchors: anchors, pinnedSHA256: server.pinnedCertificateSHA256)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: API

    /// QEMU VMs (no templates) visible to the token, sorted by name.
    public func virtualMachines() async throws(ProxmoxError) -> [ProxmoxVM] {
        let data = try await request("GET", "cluster/resources", query: [("type", "vm")])
        guard let list = data as? [[String: Any]] else { throw .invalidResponse }
        return list.compactMap { entry -> ProxmoxVM? in
            guard entry["type"] as? String == "qemu", (entry["template"] as? Int ?? 0) == 0,
                  let vmid = entry["vmid"] as? Int, let node = entry["node"] as? String else { return nil }
            return ProxmoxVM(vmid: vmid, name: entry["name"] as? String ?? "VM \(vmid)", node: node,
                             status: entry["status"] as? String ?? "unknown")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `list` with paused VMs recognised: one status call per running VM, at most 8 at a
    /// time; VMs whose status can't be read keep their listed state.
    public func withDetailedStates(_ list: [ProxmoxVM]) async -> [ProxmoxVM] {
        var result = list
        let running = list.indices.filter { list[$0].isRunning }
        for batch in stride(from: 0, to: running.count, by: 8) {
            let indices = running[batch..<min(batch + 8, running.count)]
            await withTaskGroup(of: (Int, String?).self) { group in
                for index in indices {
                    let vm = list[index]
                    group.addTask { (index, try? await self.status(node: vm.node, vmid: vm.vmid)) }
                }
                for await (index, status) in group {
                    if let status { result[index].status = status }
                }
            }
        }
        return result
    }

    /// `running`, `paused`, `stopped`, … (QMP status when available: `status` alone never
    /// says `paused`).
    public func status(node: String, vmid: Int) async throws(ProxmoxError) -> String {
        let node = try segment(node)
        let data = try await request("GET", "nodes/\(node)/qemu/\(vmid)/status/current")
        guard let object = data as? [String: Any], let status = object["status"] as? String else { throw .invalidResponse }
        if status == "running", let qmp = object["qmpstatus"] as? String { return qmp }
        return status
    }

    public func perform(_ action: ProxmoxPowerAction, node: String, vmid: Int) async throws(ProxmoxError) {
        let node = try segment(node)
        _ = try await request("POST", "nodes/\(node)/qemu/\(vmid)/status/\(action.rawValue)")
    }

    /// A fresh SPICE connection file (virt-viewer format) for the VM, as the web UI's
    /// "SPICE" button produces. Requires VM.Console.
    static func isQMPTimeout(_ message: String) -> Bool {
        message.contains("qmp command") && message.contains("timeout")
    }

    public func spiceConnectionFile(node: String, vmid: Int) async throws(ProxmoxError) -> String {
        let node = try segment(node)
        var attempt = 0
        let data: Any
        while true {
            do {
                data = try await request("POST", "nodes/\(node)/qemu/\(vmid)/spiceproxy",
                                         form: [("proxy", server.host)])
                break
            } catch .http(let status, let message) where status == 500 && Self.isQMPTimeout(message) {
                // QEMU's monitor was busy (backup, snapshot, heavy I/O) and Proxmox gave up
                // on `query-spice` after a few seconds: usually fine on a second try.
                attempt += 1
                guard attempt < 3 else { throw .qemuNotResponding(vmid: vmid) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        guard let object = data as? [String: Any] else { throw .invalidResponse }
        var lines = ["[virt-viewer]"]
        for (key, value) in object.sorted(by: { $0.key < $1.key })
        where !key.isEmpty && key.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) {
            let text: String
            switch value {
            case let string as String: text = string
            case let number as NSNumber: text = number.stringValue
            default: continue
            }
            // GKeyFile escaping so the result goes through the normal, validating parser.
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            lines.append("\(key)=\(escaped)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Transport

    private func segment(_ text: String) throws(ProxmoxError) -> String {
        // Node names are host names; refuse anything that could change the path.
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }) else {
            throw .invalidConfiguration("node name")
        }
        return text
    }

    private func request(_ method: String, _ path: String, query: [(String, String)] = [],
                         form: [(String, String)] = []) async throws(ProxmoxError) -> Any {
        var components = URLComponents()
        components.scheme = "https"
        components.host = server.host.hasPrefix("[") ? String(server.host.dropFirst().dropLast()) : server.host
        components.port = server.port
        components.path = "/api2/json/" + path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let url = components.url else { throw .invalidConfiguration("URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" {
            var body = URLComponents()
            body.queryItems = form.map { URLQueryItem(name: $0.0, value: $0.1) }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
        }

        trust.clearRejection()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.receive(request, on: session, limit: Self.maxResponseBytes)
        } catch ResponseTooLarge.exceeded {
            throw .invalidResponse
        } catch {
            if let fingerprint = trust.rejectedFingerprint { throw .untrustedCertificate(sha256: fingerprint) }
            throw .transport((error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .invalidResponse }
        let json = try? JSONSerialization.jsonObject(with: data)
        switch http.statusCode {
        case 200..<300:
            guard let object = json as? [String: Any], let payload = object["data"] else { throw .invalidResponse }
            return payload
        case 401:
            throw .unauthorized
        case 403:
            throw .forbidden(Self.message(json, http))
        default:
            throw .http(status: http.statusCode, message: Self.message(json, http))
        }
    }

    static let maxResponseBytes = 8 * 1024 * 1024

    private enum ResponseTooLarge: Error { case exceeded }

    /// Reads the body while it arrives and stops as soon as it passes `limit`, so a
    /// misbehaving server can't make the app buffer an unbounded response.
    private static func receive(_ request: URLRequest, on session: URLSession, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            throw ResponseTooLarge.exceeded
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit {
                bytes.task.cancel()
                throw ResponseTooLarge.exceeded
            }
        }
        return (data, response)
    }

    private static func message(_ json: Any?, _ response: HTTPURLResponse) -> String {
        if let object = json as? [String: Any], let message = object["message"] as? String {
            return String(message.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
    }
}

/// Server-trust evaluation for the API connection.
final class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {  // immutable + Mutex
    private let host: String
    private let anchors: [SecCertificate]
    private let pinnedSHA256: String?
    private let lastRejected = Mutex<String?>(nil)

    init(host: String, anchors: [SecCertificate], pinnedSHA256: String?) {
        self.host = host
        self.anchors = anchors
        self.pinnedSHA256 = pinnedSHA256?.lowercased()
    }

    func clearRejection() { lastRejected.withLock { $0 = nil } }

    /// Fingerprint of the last certificate refused (for the "trust this certificate?" prompt).
    var rejectedFingerprint: String? { lastRejected.withLock { $0 } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        let fingerprint = Self.leafFingerprint(trust)
        if let pinnedSHA256, let fingerprint, fingerprint == pinnedSHA256 {
            return (.useCredential, URLCredential(trust: trust))
        }
        let bareHost = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, bareHost as CFString))
        if !anchors.isEmpty {
            // Cluster CA *in addition to* the system roots (ACME certificates keep working).
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, false)
        }
        if SecTrustEvaluateWithError(trust, nil) {
            return (.useCredential, URLCredential(trust: trust))
        }
        lastRejected.withLock { $0 = fingerprint }
        return (.cancelAuthenticationChallenge, nil)
    }

    static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
