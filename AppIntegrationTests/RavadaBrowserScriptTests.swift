import Foundation
import SpiceKit
import Testing
import WebKit
@testable import SpiceClient

@MainActor
struct RavadaBrowserScriptTests {
    @Test func clientWorldDoesNotUsePortalPageGlobals() async throws {
        let fixture = BrowserFixture()
        try await fixture.load()
        _ = try await fixture.view.evaluateJavaScript("globalThis.syntheticPageMarker = true; globalThis.fetch = () => Promise.resolve({text: () => 'page replacement'}); true;")
        let result = try await fixture.view.callAsyncJavaScript("""
            return {isolated: typeof globalThis.syntheticPageMarker === 'undefined',
                    body: await (await fetch('data:application/json,%5B%5D')).text()};
            """, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(result?["isolated"] as? Bool == true)
        #expect(result?["body"] as? String == "[]")
    }

    @Test func actualReadScriptBoundsStreamAndRefusesUnexpectedRedirectURL() async throws {
        let fixture = BrowserFixture()
        try await fixture.load()
        let stub = """
            globalThis.fetch = async (url, options) => {
                if (options.method !== 'GET' || options.credentials !== 'same-origin'
                    || options.redirect !== 'error' || options.mode !== 'same-origin'
                    || options.referrerPolicy !== 'no-referrer') throw new Error('bad policy');
                let sent = false;
                return {url: redirected ? 'https://other.example.invalid/' : url, status: 200,
                    headers: {get: key => key === 'Content-Type' ? 'application/json' : null},
                    body: {cancel: async () => {}, getReader: () => ({
                        read: async () => { if (sent) return {done: true}; sent = true;
                            return {done: false, value: new TextEncoder().encode(payload)}; },
                        cancel: async () => {}
                    })}};
            };
            """
        for (payload, redirected, expected) in [("[]", false, "success"), ("12345", false, "size"), ("[]", true, "origin")] {
            let result = try await fixture.view.callAsyncJavaScript(stub + RavadaBrowserTransport.readScript,
                arguments: ["requestID": UUID().uuidString, "endpointURL": "about:blank",
                            "byteLimit": 4, "timeoutMS": 1000, "payload": payload, "redirected": redirected],
                in: nil, contentWorld: .defaultClient) as? [String: Any]
            if expected == "success" { #expect(result?["body"] as? String == "[]") }
            else { #expect(result?["failure"] as? String == expected) }
        }
    }
    @Test func actualReadScriptDeadlineAbortsPendingFetch() async throws {
        let fixture = BrowserFixture()
        try await fixture.load()
        let stub = """
            globalThis.fetch = (url, options) => new Promise((resolve, reject) => {
                options.signal.addEventListener('abort', () => reject(new Error('aborted')));
            });
            """
        let result = try await fixture.view.callAsyncJavaScript(stub + RavadaBrowserTransport.readScript,
            arguments: ["requestID": UUID().uuidString, "endpointURL": "about:blank",
                        "byteLimit": 4, "timeoutMS": 30], in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(result?["failure"] as? String == "timeout")
    }

    @Test func delayedCancellationAbortsOnlyItsOwnReadAfterAnotherStarts() async throws {
        let fixture = BrowserFixture()
        try await fixture.load()
        let stub = """
            if (!globalThis.__fixtureSignals) globalThis.__fixtureSignals = new Map();
            globalThis.fetch = (url, options) => new Promise((resolve, reject) => {
                globalThis.__fixtureSignals.set(requestID, options.signal);
                options.signal.addEventListener('abort', () => reject(new Error('aborted')));
            });
            """
        func start(_ id: String) -> Task<String?, any Error> {
            Task {
                let value = try await fixture.view.callAsyncJavaScript(stub + RavadaBrowserTransport.readScript,
                    arguments: ["requestID": id, "endpointURL": "about:blank", "byteLimit": 4, "timeoutMS": 3000],
                    in: nil, contentWorld: .defaultClient) as? [String: Any]
                return value?["failure"] as? String
            }
        }
        let first = start("first")
        let second = start("second")
        var started = false
        for _ in 0..<100 {
            started = (try await fixture.view.callAsyncJavaScript(
                "return globalThis.__fixtureSignals?.size === 2;", arguments: [:], in: nil,
                contentWorld: .defaultClient) as? Bool) == true
            if started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(started)
        _ = try await fixture.view.callAsyncJavaScript(RavadaBrowserTransport.cancelScript,
            arguments: ["requestID": "first"], in: nil, contentWorld: .defaultClient)
        let signals = try await fixture.view.callAsyncJavaScript(
            "return [globalThis.__fixtureSignals.get('first').aborted, globalThis.__fixtureSignals.get('second').aborted];",
            arguments: [:], in: nil, contentWorld: .defaultClient) as? [Bool]
        #expect(signals == [true, false])
        _ = try await fixture.view.callAsyncJavaScript(RavadaBrowserTransport.cancelScript,
            arguments: ["requestID": "second"], in: nil, contentWorld: .defaultClient)
        #expect(try await first.value == "network")
        #expect(try await second.value == "network")
    }

}

@MainActor
private final class BrowserFixture: NSObject, WKNavigationDelegate {
    let view: WKWebView
    private var completion: CheckedContinuation<Void, any Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.navigationDelegate = self
    }

    func load() async throws {
        try await withCheckedThrowingContinuation { completion in
            self.completion = completion
            view.loadHTMLString("<html><body>Synthetic broker fixture</body></html>", baseURL: nil)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.finish(.failure(RavadaBrokerError.timedOut))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }
    private func finish(_ result: Result<Void, any Error>) {
        let completion = completion
        self.completion = nil
        completion?.resume(with: result)
    }
}
