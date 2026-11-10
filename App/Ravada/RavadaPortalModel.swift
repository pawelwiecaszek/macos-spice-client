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
    let catalogCheck: RavadaCatalogCheck
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var isDownloading = false
    private(set) var requiresSignIn = false
    private(set) var launchNotice: String?
    var failure: RavadaPortalFailure?
    private(set) var diagnostics = RavadaPortalDiagnostics()

    var isBusy: Bool { isLoading || isDownloading || !approvedConversions.isEmpty }

    private var approvedConversions: Set<ObjectIdentifier> = []

    @ObservationIgnored private let readFile: @Sendable (URL) async -> Result<ConnectionProfile, any Error>
    @ObservationIgnored private let openConnection: @MainActor (ConnectionProfile, Int?) -> Bool

    @ObservationIgnored private var activeDownload: WKDownload?
    @ObservationIgnored private var destination: URL?
    @ObservationIgnored private var downloadMachineID: Int?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private(set) var isPresented = true
    @ObservationIgnored private var currentNavigation: WKNavigation?
    @ObservationIgnored private var cancelledNavigations: [WKNavigation] = []
    @ObservationIgnored private var launchGate = RavadaPortalLaunchGate()

    nonisolated static let maxConnectionFileBytes = 1024 * 1024

    init(portalURL: URL, dataStore: WKWebsiteDataStore? = nil,
         readFile: (@Sendable (URL) async -> Result<ConnectionProfile, any Error>)? = nil,
         openConnection: (@MainActor (ConnectionProfile) -> Bool)? = nil,
         openConnectionWithIdentity: (@MainActor (ConnectionProfile, Int?) -> Bool)? = nil) {
        self.portalURL = portalURL
        self.readFile = readFile ?? { url in await Self.readAndRemoveConnectionFile(at: url) }
        self.openConnection = openConnectionWithIdentity ?? { profile, _ in
            (openConnection ?? { SessionWindowManager.shared.openSession($0) })(profile)
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore ?? .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        let transport = try? RavadaBrowserTransport(portalURL: portalURL, webView: webView)
        catalogCheck = RavadaCatalogCheck(read: {
            guard let transport else { throw RavadaBrokerError.invalidAddress }
            return try await transport.catalog()
        }, cancel: { transport?.cancel() })
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func load() {
        guard !stopped else { return }
        cancelCurrentAction()
        failure = nil
        // Always return to the configured portal with a fresh GET, never replay an
        // expired POST or a machine action URL as an automatic recovery attempt.
        currentNavigation = webView.load(URLRequest(url: portalURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                                    timeoutInterval: 30))
    }

    func cancelCurrentAction() {
        catalogCheck.cancel()
        let wasBusy = isBusy
        if let currentNavigation {
            cancelledNavigations.append(currentNavigation)
            if cancelledNavigations.count > 32 { cancelledNavigations.removeFirst() }
        }
        currentNavigation = nil
        webView.stopLoading()
        cancelDownload()
        isLoading = false
        if wasBusy { diagnostics.record(.userCancellations) }
    }

    func stop() {
        stopped = true
        cancelCurrentAction()
    }

    /// Keep browser state while hidden, but admit no navigation or session handoffs.
    func pause() {
        isPresented = false
        cancelCurrentAction()
    }

    func resume() {
        if !stopped { isPresented = true }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard !stopped, isPresented, let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // HTTPS identity-provider redirects may leave the portal origin. Only actual
        // connection-file downloads are restricted to the configured portal origin.
        guard url.scheme?.lowercased() == "https" || url.absoluteString == "about:blank" else {
            report(.init(kind: .unsupportedAddress, phase: .loadingPortal))
            decisionHandler(.cancel)
            return
        }
        if url.pathExtension.lowercased() == "vv",
           !RavadaPortalConfiguration.sameOrigin(url, as: portalURL) {
            report(.init(kind: .untrustedDownload, phase: .downloadingConnection))
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(approveDownloadConversion(navigationAction) ? .download : .cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        guard !stopped, isPresented else { decisionHandler(.cancel); return }
        let response = navigationResponse.response
        if RavadaPortalConfiguration.shouldDisplaySignInPage(
            response, portalURL: portalURL, isMainFrame: navigationResponse.isForMainFrame,
            canShowMIMEType: navigationResponse.canShowMIMEType) {
            requiresSignIn = true
            diagnostics.record(.signInPages)
            decisionHandler(.allow)
            return
        }
        if RavadaPortalConfiguration.isConnectionFile(response) {
            if let failure = RavadaPortalFailure.responseFailure(
                response, portalURL: portalURL, isMainFrame: navigationResponse.isForMainFrame) {
                report(failure)
                decisionHandler(.cancel)
            } else {
                decisionHandler(approveDownloadConversion(navigationResponse) ? .download : .cancel)
            }
        } else if navigationResponse.isForMainFrame,
                  let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            // Only the configured origin can assert that the Ravada session expired.
            let kind: RavadaPortalFailure.Kind
            if RavadaPortalConfiguration.sameOrigin(response.url, as: portalURL) {
                kind = http.statusCode == 401 ? .signInRequired
                    : (http.statusCode == 403 ? .permissionDenied : .server)
            } else {
                kind = .server
            }
            report(.init(kind: kind, phase: .loadingPortal))
            decisionHandler(.cancel)
        } else {
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        begin(download, conversion: navigationAction)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        begin(download, conversion: navigationResponse)
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
        guard !stopped, isPresented, !cancelledNavigations.contains(where: { $0 === navigation }) else { return }
        catalogCheck.cancel()
        currentNavigation = navigation
        failure = nil
        requiresSignIn = false
        isLoading = true
        diagnostics.record(.pageLoads)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !stopped, isPresented, navigation === currentNavigation else { return }
        updateNavigation()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !stopped, isPresented, navigation === currentNavigation else { return }
        // A newly rendered portal page may auto-launch once after Start finishes.
        // Download conversions do not commit a new document, so they cannot rearm it.
        launchGate.beganDocument()
        launchNotice = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        navigationFailed(error, navigation: navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        navigationFailed(error, navigation: navigation)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        updateNavigation()
        guard !stopped else { return }
        cancelDownload()
        report(.init(kind: .browserStopped, phase: .loadingPortal))
    }

    private func updateNavigation() {
        isLoading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func navigationFailed(_ error: any Error, navigation: WKNavigation?) {
        guard !stopped, isPresented, navigation === currentNavigation,
              !cancelledNavigations.contains(where: { $0 === navigation }) else { return }
        updateNavigation()
        if let failure = RavadaPortalFailure.classify(error, phase: .loadingPortal) {
            report(failure)
        } else {
            diagnostics.record(.ignoredNavigationCancellations)
        }
    }

    func approveDownloadConversion(_ conversion: AnyObject) -> Bool {
        guard !stopped, isPresented, !isDownloading, approvedConversions.isEmpty else { return false }
        approvedConversions.insert(ObjectIdentifier(conversion))
        return true
    }

    func consumeDownloadConversion(_ conversion: AnyObject) -> Bool {
        approvedConversions.remove(ObjectIdentifier(conversion)) != nil
    }

    private func begin(_ download: WKDownload, conversion: AnyObject) {
        guard consumeDownloadConversion(conversion), !stopped, isPresented, !isDownloading,
              download.originatingFrame.isMainFrame,
              RavadaPortalConfiguration.sameOrigin(download.originalRequest?.url, as: portalURL) else {
            download.cancel(nil)
            return
        }
        // Ravada v2.4.6's machine_info callback may auto-download after a manual
        // View has already succeeded. Its manual anchor does not set redirected_display.
        // Reference: UPC/ravada@9e1dd6b, public/js/ravada.js:1749-1757 and
        // templates/main/machine_displays.html.ep:64-71. Keep the first automatic
        // handoff, but require WebKit's user-gesture flag for any subsequent one.
        guard acceptConnectionOffer(isUserInitiated: download.isUserInitiated) else {
            download.cancel(nil)
            return
        }
        generation = UUID()
        failure = nil
        isDownloading = true
        diagnostics.record(.downloadsStarted)
        activeDownload = download
        download.delegate = self
        monitorDownload(download)
    }

    func acceptConnectionOffer(isUserInitiated: Bool) -> Bool {
        guard !stopped, isPresented else { return false }
        guard launchGate.accept(isUserInitiated: isUserInitiated) else {
            diagnostics.record(.automaticLaunchesBlocked)
            launchNotice = String(localized: "An extra automatic connection was ignored. Click View in the portal if you want to reconnect.")
            return false
        }
        launchNotice = nil
        return true
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard download === activeDownload else { completionHandler(nil); return }
        if let failure = RavadaPortalFailure.responseFailure(
            response, portalURL: portalURL, filename: suggestedFilename) {
            completionHandler(nil)
            cancelDownload()
            report(failure)
            return
        }
        downloadMachineID = RavadaPortalConfiguration.machineID(displayURL: response.url, portalURL: portalURL)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ravada-\(UUID().uuidString).vv")
        destination = url
        completionHandler(url)
    }

    private func monitorDownload(_ download: WKDownload) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        monitor = Task { [weak self, weak download] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, let download, self.activeDownload === download else { return }
                let size = (try? self.destination?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if download.progress.completedUnitCount > Int64(Self.maxConnectionFileBytes)
                    || size > Self.maxConnectionFileBytes || ContinuousClock.now >= deadline {
                    let kind: RavadaPortalFailure.Kind = ContinuousClock.now >= deadline ? .timeout : .fileTooLarge
                    self.cancelDownload()
                    self.report(.init(kind: kind, phase: .downloadingConnection))
                    return
                }
            }
        }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  decisionHandler: @escaping @MainActor (WKDownload.RedirectPolicy) -> Void) {
        guard download === activeDownload else { decisionHandler(.cancel); return }
        guard RavadaPortalConfiguration.sameOrigin(request.url, as: portalURL) else {
            decisionHandler(.cancel)
            cancelDownload()
            report(.init(kind: .untrustedDownload, phase: .downloadingConnection))
            return
        }
        decisionHandler(.allow)
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
        let completedGeneration = generation
        let machineID = downloadMachineID
        downloadMachineID = nil
        Task { await openDownloadedConnectionFile(at: url, expectedGeneration: completedGeneration, machineID: machineID) }
    }

    /// Kept separate from WebKit delivery to exercise parsing and late cancellation
    /// without making authenticated network requests in the test suite.
    func openDownloadedConnectionFile(at url: URL, expectedGeneration: UUID? = nil, machineID: Int? = nil) async {
        let currentGeneration = expectedGeneration ?? generation
        guard !stopped, isPresented, currentGeneration == generation else {
            await Task.detached { try? FileManager.default.removeItem(at: url) }.value
            return
        }
        isDownloading = true
        let result = await readFile(url)
        guard !stopped, isPresented, generation == currentGeneration else { return }
        isDownloading = false
        switch result {
        case .success(let profile):
            diagnostics.record(.filesValidated)
            if openConnection(profile, machineID) { diagnostics.record(.sessionsOpened) }
        case .failure(let error):
            if let failure = RavadaPortalFailure.classify(error, phase: .readingConnection) {
                report(failure)
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard download === activeDownload else { return }
        cancelDownload()
        if !stopped, let failure = RavadaPortalFailure.classify(error, phase: .downloadingConnection) {
            report(failure)
        }
    }

    private func report(_ failure: RavadaPortalFailure) {
        self.failure = failure
        diagnostics.record(failure)
        if failure.kind == .untrustedDownload { diagnostics.record(.rejectedDownloads) }
    }

    private func cancelDownload() {
        downloadMachineID = nil
        // Invalidates an already completed download that is still being parsed.
        generation = UUID()
        launchGate.invalidate()
        approvedConversions.removeAll()
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

    private nonisolated static func readAndRemoveConnectionFile(at url: URL) async -> Result<ConnectionProfile, any Error> {
        await Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: url) }
            return Result { try Self.readConnectionFile(at: url) }
        }.value
    }

    nonisolated static func readConnectionFile(at url: URL) throws -> ConnectionProfile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxConnectionFileBytes + 1) ?? Data()
        guard data.count <= maxConnectionFileBytes else { throw RavadaPortalFailure(kind: .fileTooLarge, phase: .readingConnection) }
        var profile = try VVFileParser.parse(Array(data)).profile
        // The portal launches ordinary session windows even when its generated file
        // requests fullscreen. Users can still enter fullscreen from the session UI.
        profile.fullscreen = false
        return profile
    }

}
