import Foundation
import SpiceKit
import WebKit

/// Executes release-verified broker requests inside WebKit's isolated client world. Cookies,
/// including HttpOnly session cookies, stay in the profile's WebKit data store.
@MainActor
final class RavadaBrowserTransport {
    typealias Evaluate = @MainActor (String, [String: Any]) async throws -> Any
    private let endpoint: RavadaEndpoint
    private let pageURL: @MainActor () -> URL?
    private let evaluate: Evaluate
    private var activeID: String?

    init(portalURL: URL, pageURL: @escaping @MainActor () -> URL?, evaluate: @escaping Evaluate) throws {
        endpoint = try RavadaEndpoint(portalURL: portalURL)
        self.pageURL = pageURL
        self.evaluate = evaluate
    }

    convenience init(portalURL: URL, webView: WKWebView) throws {
        try self.init(portalURL: portalURL, pageURL: { webView.url }) { script, arguments in
            try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .defaultClient) ?? NSNull()
        }
    }

    func catalog() async throws -> RavadaCatalog {
        let response = try await request(.catalog)
        return try RavadaCatalog.decode(response.data, status: response.status, contentType: response.contentType)
    }

    func request(_ request: RavadaBrokerRequest) async throws -> RavadaBrokerResponse {
        let requestURL = try request.url(using: endpoint)
        guard activeID == nil else { throw RavadaBrokerError.unavailable }
        guard let page = pageURL(), endpoint.contains(page) else { throw RavadaBrokerError.signInRequired }
        let id = UUID().uuidString
        activeID = id
        defer { if activeID == id { activeID = nil } }
        return try await withTaskCancellationHandler {
            let value: Any
            do {
                value = try await evaluate(Self.readScript, [
                    "requestID": id, "endpointURL": requestURL.absoluteString,
                    "byteLimit": RavadaCatalog.maxResponseBytes, "timeoutMS": 15000
                ])
            } catch {
                guard activeID == id, !Task.isCancelled else { throw RavadaBrokerError.cancelled }
                throw request.isMutation ? RavadaBrokerError.ambiguousStart : .unavailable
            }
            guard activeID == id, !Task.isCancelled, pageURL() == page else { throw RavadaBrokerError.cancelled }
            guard let response = value as? [String: Any] else { throw RavadaBrokerError.invalidResponse }
            if let failure = response["failure"] as? String {
                switch failure {
                case "timeout": throw request.isMutation ? RavadaBrokerError.ambiguousStart : .timedOut
                case "size": throw RavadaBrokerError.responseTooLarge
                case "origin": throw RavadaBrokerError.redirectRejected
                default: throw request.isMutation ? RavadaBrokerError.ambiguousStart : .unavailable
                }
            }
            guard let status = response["status"] as? Int,
                  let urlText = response["url"] as? String, let url = URL(string: urlText),
                  let contentType = response["contentType"] as? String,
                  let body = response["body"] as? String else { throw RavadaBrokerError.invalidResponse }
            guard url == requestURL else { throw RavadaBrokerError.redirectRejected }
            return RavadaBrokerResponse(data: Data(body.utf8), status: status, contentType: contentType)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(requestID: id) }
        }
    }

    func cancel() {
        if let id = activeID { cancel(requestID: id) }
    }

    private func cancel(requestID: String) {
        guard activeID == requestID else { return }
        activeID = nil
        let evaluate = evaluate
        Task {
            _ = try? await evaluate(Self.cancelScript, ["requestID": requestID])
        }
    }

    static let cancelScript = """
        const current = globalThis.__spiceRavadaReads?.get(requestID);
        if (current) current.abort();
        """

    // fetch runs in defaultClient, not the portal's JavaScript world. The only URL
    // argument is built by RavadaBrokerRequest/RavadaEndpoint. redirect:error refuses even same-origin
    // login redirects before any second request; no credentials leave this origin.
    static let readScript = """
        const endpoint = new URL(endpointURL);
        if (location.origin !== endpoint.origin) return {failure: 'origin'};
        const controller = new AbortController();
        if (!globalThis.__spiceRavadaReads) globalThis.__spiceRavadaReads = new Map();
        globalThis.__spiceRavadaReads.set(requestID, controller);
        let timedOut = false;
        const timer = setTimeout(() => { timedOut = true; controller.abort(); }, timeoutMS);
        try {
            const response = await fetch(endpoint.href, {
                method: 'GET', credentials: 'same-origin', mode: 'same-origin',
                redirect: 'error', cache: 'no-store', referrerPolicy: 'no-referrer',
                headers: {'Accept': 'application/json'}, signal: controller.signal
            });
            if (response.url !== endpoint.href) return {failure: 'origin'};
            const contentType = response.headers.get('Content-Type') || '';
            if (response.status !== 200) {
                if (response.body) await response.body.cancel();
                return {status: response.status, url: response.url, contentType, body: ''};
            }
            const length = response.headers.get('Content-Length');
            if (length !== null && Number(length) > byteLimit) {
                if (response.body) await response.body.cancel();
                return {failure: 'size'};
            }
            if (!response.body) return {failure: 'response'};
            const reader = response.body.getReader();
            const decoder = new TextDecoder('utf-8', {fatal: true});
            let total = 0;
            let body = '';
            while (true) {
                const chunk = await reader.read();
                if (chunk.done) break;
                total += chunk.value.byteLength;
                if (total > byteLimit) { await reader.cancel(); return {failure: 'size'}; }
                body += decoder.decode(chunk.value, {stream: true});
            }
            body += decoder.decode();
            return {status: response.status, url: response.url, contentType, body};
        } catch (_) {
            return {failure: timedOut ? 'timeout' : 'network'};
        } finally {
            clearTimeout(timer);
            globalThis.__spiceRavadaReads?.delete(requestID);
        }
        """
}
