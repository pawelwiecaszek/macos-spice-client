import AppKit
import Observation
import SpiceKit
import WebKit

/// WebKit owns portal authentication and the original download request, including POST
/// bodies. Connection files are never replayed through a second HTTP client.
@MainActor
@Observable
final class RavadaPortalModel: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let portalURL: URL
    let webView: WKWebView
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var isDownloading = false
    var errorMessage: String?

    @ObservationIgnored private var activeDownload: WKDownload?
    @ObservationIgnored private var destination: URL?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var stopped = false

    nonisolated static let maxConnectionFileBytes = 1024 * 1024

    init(portalURL: URL) {
        self.portalURL = portalURL
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = RavadaPortalConfiguration.websiteDataStore(for: portalURL)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func load() {
        guard !stopped else { return }
        webView.load(URLRequest(url: portalURL))
    }

    func stop() {
        stopped = true
        generation = UUID()
        webView.stopLoading()
        cancelDownload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard !stopped, let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // HTTPS identity-provider redirects may leave the portal origin. Only actual
        // connection-file downloads are restricted to the configured portal origin.
        guard url.scheme?.lowercased() == "https" || url.absoluteString == "about:blank" else {
            errorMessage = String(localized: "The portal tried to open an insecure or unsupported address.")
            decisionHandler(.cancel)
            return
        }
        if url.pathExtension.lowercased() == "vv",
           !RavadaPortalConfiguration.sameOrigin(url, as: portalURL) {
            errorMessage = String(localized: "Connection files must come from the configured Ravada portal.")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        guard !stopped else { decisionHandler(.cancel); return }
        let response = navigationResponse.response
        if RavadaPortalConfiguration.isConnectionFile(response) {
            guard navigationResponse.isForMainFrame,
                  RavadaPortalConfiguration.sameOrigin(response.url, as: portalURL),
                  response.expectedContentLength <= Int64(Self.maxConnectionFileBytes),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                errorMessage = String(localized: "The portal returned an invalid or oversized connection file.")
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.download)
        } else {
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        begin(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        begin(download)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Ravada may use target=_blank for the console link. Keep that request in this
        // portal so it uses the same session and download policy.
        if navigationAction.targetFrame == nil,
           RavadaPortalConfiguration.sameOrigin(navigationAction.request.url, as: portalURL) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateNavigation()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        navigationFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        updateNavigation()
        errorMessage = String(localized: "The portal browser stopped. Reload the page to continue.")
    }

    private func updateNavigation() {
        isLoading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func navigationFailed(_ error: any Error) {
        updateNavigation()
        guard !stopped, !RavadaPortalConfiguration.isExpectedNavigationCancellation(error) else { return }
        errorMessage = String(localized: "The secure portal could not be loaded. Check its address, certificate, and your network connection, then reload.")
    }

    private func begin(_ download: WKDownload) {
        guard !stopped, !isDownloading,
              RavadaPortalConfiguration.sameOrigin(download.originalRequest?.url, as: portalURL) else {
            download.cancel(nil)
            return
        }
        isDownloading = true
        activeDownload = download
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard download === activeDownload,
              RavadaPortalConfiguration.sameOrigin(response.url, as: portalURL),
              RavadaPortalConfiguration.isConnectionFile(response, filename: suggestedFilename),
              response.expectedContentLength <= Int64(Self.maxConnectionFileBytes),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            completionHandler(nil)
            cancelDownload()
            errorMessage = String(localized: "The portal returned an invalid or oversized connection file.")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ravada-\(UUID().uuidString).vv")
        destination = url
        completionHandler(url)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        monitor = Task { [weak self, weak download] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, let download, self.activeDownload === download else { return }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if download.progress.completedUnitCount > Int64(Self.maxConnectionFileBytes)
                    || size > Self.maxConnectionFileBytes || ContinuousClock.now >= deadline {
                    self.cancelDownload()
                    self.errorMessage = String(localized: "The connection-file download exceeded its size or time limit. Choose the machine again to retry.")
                    return
                }
            }
        }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  decisionHandler: @escaping @MainActor (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(RavadaPortalConfiguration.sameOrigin(request.url, as: portalURL) ? .allow : .cancel)
    }

    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Retain the system's certificate and hostname validation. Downloaded CA data
        // belongs only to its SPICE session; it never changes portal trust.
        completionHandler(.performDefaultHandling, nil)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard download === activeDownload, let url = destination else { return }
        monitor?.cancel()
        monitor = nil
        activeDownload = nil
        destination = nil
        let currentGeneration = generation
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                defer { try? FileManager.default.removeItem(at: url) }
                return Result { try Self.readConnectionFile(at: url) }
            }.value
            guard !stopped, generation == currentGeneration else { return }
            isDownloading = false
            switch result {
            case .success(let profile): SessionWindowManager.shared.openSession(profile)
            case .failure:
                errorMessage = String(localized: "The portal did not return a valid SPICE connection file. Sign in and choose the machine again.")
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard download === activeDownload else { return }
        cancelDownload()
        if !stopped {
            errorMessage = String(localized: "The connection file could not be downloaded. Sign in and choose the machine again.")
        }
    }

    private func cancelDownload() {
        monitor?.cancel()
        monitor = nil
        let url = destination
        destination = nil
        let download = activeDownload
        activeDownload = nil
        isDownloading = false
        download?.delegate = nil
        if let download {
            // Remove partial data only after WebKit has stopped writing it.
            download.cancel { _ in if let url { try? FileManager.default.removeItem(at: url) } }
        } else if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated static func readConnectionFile(at url: URL) throws -> ConnectionProfile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxConnectionFileBytes + 1) ?? Data()
        guard data.count <= maxConnectionFileBytes else { throw PortalFileError.tooLarge }
        var profile = try VVFileParser.parse(Array(data)).profile
        // The portal launches ordinary session windows even when its generated file
        // requests fullscreen. Users can still enter fullscreen from the session UI.
        profile.fullscreen = false
        return profile
    }

    private enum PortalFileError: Error { case tooLarge }
}
