import Foundation
import SpiceKit
import Testing
import WebKit
@testable import SpiceClient

@MainActor
struct RavadaPortalLifecycleTests {
    private func makeURL() throws -> URL {
        try #require(URL(string: "https://portal.example.invalid/"))
    }

    @Test func normalDownloadInterruptionDoesNotHideRealCertificateErrors() throws {
        let model = RavadaPortalModel(portalURL: try makeURL(), dataStore: .nonPersistent())
        defer { model.stop() }
        model.webView(model.webView, didFailProvisionalNavigation: nil,
                      withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted))
        #expect(model.failure?.kind == .certificate)
        model.webView(model.webView, didFailProvisionalNavigation: nil,
                      withError: NSError(domain: "WebKitErrorDomain", code: 102))
        #expect(model.failure?.kind == .certificate)
        #expect(model.diagnostics.summary.contains("ignoredNavigationCancellations: 1"))
    }

    @Test func tenSuccessiveConnectionFilesAreRemovedAndOpenWindowed() async throws {
        var opened = 0
        let model = RavadaPortalModel(portalURL: try makeURL(), dataStore: .nonPersistent(),
                                     openConnection: { profile in
            #expect(!profile.fullscreen)
            opened += 1
            return true
        })
        defer { model.stop() }
        for _ in 0..<10 {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vv")
            try Data("[virt-viewer]\ntype=spice\nhost=example.invalid\nport=5930\nfullscreen=1\n".utf8)
                .write(to: file)
            await model.openDownloadedConnectionFile(at: file)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(model.failure == nil)
            #expect(!model.isBusy)
        }
        #expect(opened == 10)
        #expect(model.diagnostics.summary.contains("sessionsOpened: 10"))
    }

    @Test func stopCancelsPendingReadWithoutOpeningOrReportingAnError() async throws {
        let gate = ReadGate()
        var opened = 0
        let model = RavadaPortalModel(portalURL: try makeURL(), dataStore: .nonPersistent(),
                                     readFile: { _ in
            await gate.wait()
            return .success(ConnectionProfile(host: "example.invalid"))
        }, openConnection: { _ in opened += 1; return true })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("unused.vv")
        let work = Task { await model.openDownloadedConnectionFile(at: file) }
        await gate.waitUntilStarted()
        #expect(model.isDownloading)
        model.cancelCurrentAction()
        await gate.release()
        await work.value
        #expect(opened == 0)
        #expect(!model.isBusy)
        #expect(model.failure == nil)
        #expect(model.diagnostics.summary.contains("userCancellations: 1"))
        model.stop()
    }

    @Test func closingPortalDuringReadCannotLaunchALateSession() async throws {
        let gate = ReadGate()
        var opened = 0
        let model = RavadaPortalModel(portalURL: try makeURL(), dataStore: .nonPersistent(),
                                     readFile: { _ in
            await gate.wait()
            return .success(ConnectionProfile(host: "example.invalid"))
        }, openConnection: { _ in opened += 1; return true })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("unused.vv")
        let work = Task { await model.openDownloadedConnectionFile(at: file) }
        await gate.waitUntilStarted()
        model.stop()
        await gate.release()
        await work.value
        #expect(opened == 0)
        #expect(model.failure == nil)
        #expect(!model.isBusy)
    }

    @Test func invalidFilesAreRemovedAndDiagnosticsNeverContainTheirContents() async throws {
        let secret = "secret-ticket-that-must-not-escape"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vv")
        try Data("[virt-viewer]\ntype=vnc\npassword=\(secret)\n".utf8).write(to: file)
        let model = RavadaPortalModel(portalURL: try makeURL(), dataStore: .nonPersistent())
        defer { model.stop() }
        await model.openDownloadedConnectionFile(at: file)
        #expect(model.failure?.kind == .invalidConnectionFile)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!model.diagnostics.summary.contains(secret))
        #expect(!model.diagnostics.summary.contains("example.invalid"))
        #expect(!model.diagnostics.summary.contains(file.lastPathComponent))
    }

    @Test func stopRejectsLateDownloadConversionsAndAllowsANewOne() throws {
        let model = RavadaPortalModel(portalURL: try makeURL(), dataStore: .nonPersistent())
        defer { model.stop() }
        let oldConversion = NSObject()
        let approved = model.approveDownloadConversion(oldConversion)
        #expect(approved)
        #expect(model.isBusy)
        model.cancelCurrentAction()
        let stale = model.consumeDownloadConversion(oldConversion)
        #expect(!stale)
        #expect(!model.isBusy)
        let newConversion = NSObject()
        let nextApproved = model.approveDownloadConversion(newConversion)
        let nextConsumed = model.consumeDownloadConversion(newConversion)
        let duplicate = model.consumeDownloadConversion(newConversion)
        #expect(nextApproved)
        #expect(nextConsumed)
        #expect(!duplicate)
    }

    @Test func ravada401LoginFormsStayVisibleButForeignPagesCannotAssertLoginState() throws {
        let portal = try makeURL()
        let login = try #require(HTTPURLResponse(
            url: portal.appendingPathComponent("machines"), statusCode: 401,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"]))
        #expect(RavadaPortalConfiguration.shouldDisplaySignInPage(
            login, portalURL: portal, isMainFrame: true, canShowMIMEType: true))
        #expect(!RavadaPortalConfiguration.shouldDisplaySignInPage(
            login, portalURL: portal, isMainFrame: false, canShowMIMEType: true))
        #expect(!RavadaPortalConfiguration.shouldDisplaySignInPage(
            login, portalURL: portal, isMainFrame: true, canShowMIMEType: false))
        let other = try #require(URL(string: "https://other.example.invalid/"))
        #expect(!RavadaPortalConfiguration.shouldDisplaySignInPage(
            login, portalURL: other, isMainFrame: true, canShowMIMEType: true))
    }

    @Test func staleNavigationCallbacksCannotStopANewerLoad() throws {
        let model = RavadaPortalModel(portalURL: try makeURL(), dataStore: .nonPersistent())
        defer { model.stop() }
        // WebKit owns navigation objects; constructing one with NSObject.init can
        // crash because it has no underlying WebKit navigation. Local HTML makes
        // genuine objects without contacting a server.
        let old = try #require(model.webView.loadHTMLString("<html></html>", baseURL: nil))
        model.webView(model.webView, didStartProvisionalNavigation: old)
        model.cancelCurrentAction()
        let current = try #require(model.webView.loadHTMLString("<html></html>", baseURL: nil))
        model.webView(model.webView, didStartProvisionalNavigation: current)
        model.webView(model.webView, didFailProvisionalNavigation: old,
                      withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        #expect(model.isLoading)
        model.webView(model.webView, didFailProvisionalNavigation: old,
                      withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted))
        model.webView(model.webView, didFinish: old)
        #expect(model.isLoading)
        #expect(model.failure == nil)
        model.webView(model.webView, didFinish: current)
        #expect(!model.isLoading)
    }

    @Test func backgroundDuplicateIsIgnoredWithoutFalseErrorAndExplicitViewStillWorks() throws {
        let model = RavadaPortalModel(portalURL: try makeURL(), dataStore: .nonPersistent())
        defer { model.stop() }
        let page = try #require(model.webView.loadHTMLString("<html></html>", baseURL: nil))
        model.webView(model.webView, didStartProvisionalNavigation: page)
        model.webView(model.webView, didCommit: page)
        let firstView = model.acceptConnectionOffer(isUserInitiated: true)
        let lateAutomatic = model.acceptConnectionOffer(isUserInitiated: false)
        #expect(firstView)
        #expect(!lateAutomatic)
        #expect(model.launchNotice != nil)
        #expect(model.failure == nil)
        #expect(model.diagnostics.summary.contains("automaticLaunchesBlocked: 1"))
        let deliberateReconnect = model.acceptConnectionOffer(isUserInitiated: true)
        #expect(deliberateReconnect)
        #expect(model.launchNotice == nil)
    }

    @Test func hiddenPortalCannotNavigateOrOfferConnectionsAndResumesWithoutReload() throws {
        let model = RavadaPortalModel(portalURL: try makeURL(), dataStore: .nonPersistent())
        defer { model.stop() }
        let webView = model.webView
        let page = try #require(webView.loadHTMLString("<html></html>", baseURL: nil))
        model.webView(webView, didStartProvisionalNavigation: page)
        model.webView(webView, didCommit: page)
        model.pause()
        model.webView(webView, didStartProvisionalNavigation: page)
        model.webView(webView, didCommit: page)
        let hidden = model.acceptConnectionOffer(isUserInitiated: false)
        let conversion = model.approveDownloadConversion(NSObject())
        #expect(!hidden)
        #expect(!conversion)
        #expect(!model.isBusy)
        model.resume()
        #expect(model.webView === webView)
        let deliberate = model.acceptConnectionOffer(isUserInitiated: true)
        #expect(deliberate)
    }

    @Test func navigatingAwayDuringReadPreventsALateSessionOpening() async throws {
        let gate = ReadGate()
        var opened = 0
        let model = RavadaPortalModel(portalURL: try makeURL(), dataStore: .nonPersistent(),
                                     readFile: { _ in
            await gate.wait()
            return .success(ConnectionProfile(host: "example.invalid"))
        }, openConnection: { _ in opened += 1; return true })
        let work = Task {
            await model.openDownloadedConnectionFile(at: FileManager.default.temporaryDirectory.appendingPathComponent("unused.vv"))
        }
        await gate.waitUntilStarted()
        model.pause()
        await gate.release()
        await work.value
        #expect(opened == 0)
        #expect(model.failure == nil)
        model.stop()
    }
}

private actor ReadGate {
    private var started = false
    private var reader: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { reader = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        reader?.resume()
        reader = nil
    }
}
