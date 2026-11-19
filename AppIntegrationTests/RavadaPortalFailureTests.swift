import Foundation
import Testing
@testable import SpiceClient

struct RavadaPortalFailureTests {
    private func response(status: Int = 200, host: String = "portal.example.invalid", port: Int? = nil,
                          mime: String = "application/x-virt-viewer", length: String? = nil,
                          path: String = "/machine/display/spice/1.vv") throws -> HTTPURLResponse {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        components.path = path
        let url = try #require(components.url)
        var headers = ["Content-Type": mime]
        if let length { headers["Content-Length"] = length }
        return try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
    }

    private var portalURL: URL {
        get throws { try #require(URL(string: "https://portal.example.invalid/")) }
    }

    @Test func classifiesNetworkAndCertificateFailuresWithoutErrorContents() throws {
        let secret = "private-host.example.invalid?ticket=synthetic-secret"
        let privateURL = try #require(URL(string: "https://\(secret)"))
        for (code, kind) in [(NSURLErrorCannotConnectToHost, RavadaPortalFailure.Kind.network),
                             (NSURLErrorTimedOut, .timeout),
                             (NSURLErrorServerCertificateUntrusted, .certificate),
                             (NSURLErrorServerCertificateHasBadDate, .certificate),
                             (NSURLErrorUserAuthenticationRequired, .signInRequired)] {
            let error = NSError(domain: NSURLErrorDomain, code: code, userInfo: [
                NSLocalizedDescriptionKey: secret,
                NSURLErrorFailingURLErrorKey: privateURL
            ])
            let failure = try #require(RavadaPortalFailure.classify(error, phase: .loadingPortal))
            #expect(failure.kind == kind)
            #expect(failure.phase == .loadingPortal)
            #expect(!failure.message.contains(secret))
            #expect(!failure.message.contains("ticket="))
            #expect(!String(describing: failure).contains(secret))
        }
    }

    @Test func suppressesOnlyCancellationInTheExpectedDomains() {
        for error in [NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
                      NSError(domain: "WebKitErrorDomain", code: 102)] {
            #expect(RavadaPortalFailure.classify(error, phase: .loadingPortal) == nil)
        }
        for error in [NSError(domain: "OtherDomain", code: NSURLErrorCancelled),
                      NSError(domain: "OtherDomain", code: 102),
                      NSError(domain: "WebKitErrorDomain", code: 101),
                      NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)] {
            #expect(RavadaPortalFailure.classify(error, phase: .loadingPortal) != nil)
        }
    }

    @Test func distinguishesSignInPermissionAndServerResponses() throws {
        let portal = try portalURL
        for (status, kind) in [(401, RavadaPortalFailure.Kind.signInRequired),
                               (403, .permissionDenied), (500, .server), (503, .server), (404, .download)] {
            let failure = try #require(RavadaPortalFailure.responseFailure(response(status: status), portalURL: portal))
            #expect(failure.kind == kind)
            #expect(failure.phase == .downloadingConnection)
        }
        #expect(RavadaPortalFailure(kind: .signInRequired, phase: .downloadingConnection).recovery == .signIn)
        #expect(RavadaPortalFailure(kind: .permissionDenied, phase: .downloadingConnection).recovery == .chooseMachine)
    }

    @Test func allowsValidUnknownLengthAndRejectsOversizedOrHTMLBodies() throws {
        let portal = try portalURL
        #expect(try RavadaPortalFailure.responseFailure(response(), portalURL: portal) == nil)
        #expect(try RavadaPortalFailure.responseFailure(response(length: "1048576"), portalURL: portal) == nil)
        #expect(try RavadaPortalFailure.responseFailure(response(length: "1048577"), portalURL: portal)?.kind == .fileTooLarge)
        // A .vv URL can return a login page or an unrelated HTML error. Do not assert
        // authentication failure without an explicit authentication response.
        #expect(try RavadaPortalFailure.responseFailure(response(mime: "text/html"), portalURL: portal)?.kind == .invalidConnectionFile)
        #expect(try RavadaPortalFailure.responseFailure(response(mime: "application/xhtml+xml"), portalURL: portal)?.kind == .invalidConnectionFile)
        #expect(try RavadaPortalFailure.responseFailure(response(mime: "application/pdf", path: "/report"), portalURL: portal)?.kind == .invalidConnectionFile)
        let namedDownload = try response(mime: "application/octet-stream", path: "/download")
        #expect(RavadaPortalFailure.responseFailure(namedDownload, portalURL: portal, filename: "machine.tls.vv") == nil)
    }

    @Test func rejectsCrossOriginAndSubframeDownloadsBeforeStatusHandling() throws {
        let portal = try portalURL
        #expect(try RavadaPortalFailure.responseFailure(response(port: 443), portalURL: portal) == nil)
        #expect(try RavadaPortalFailure.responseFailure(response(port: 8443), portalURL: portal)?.kind == .untrustedDownload)
        #expect(try RavadaPortalFailure.responseFailure(response(status: 401, host: "other.example.invalid"), portalURL: portal)?.kind == .untrustedDownload)
        #expect(try RavadaPortalFailure.responseFailure(response(), portalURL: portal, isMainFrame: false)?.kind == .untrustedDownload)
        let fileURL = try #require(URL(string: "file:///tmp/guest.vv"))
        let fileResponse = URLResponse(url: fileURL, mimeType: "application/x-virt-viewer", expectedContentLength: 20, textEncodingName: nil)
        #expect(RavadaPortalFailure.responseFailure(fileResponse, portalURL: portal)?.kind == .untrustedDownload)
    }

    @Test func preservesPhaseAndClassifiesStorageAndParsingFailures() throws {
        let limit = RavadaPortalFailure(kind: .fileTooLarge, phase: .readingConnection)
        #expect(RavadaPortalFailure.classify(limit, phase: .loadingPortal) == limit)
        let storage = try #require(RavadaPortalFailure.classify(
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError), phase: .readingConnection))
        #expect(storage.kind == .storage)
        #expect(storage.phase == .readingConnection)
        let parse = try #require(RavadaPortalFailure.classify(
            NSError(domain: "SyntheticParser", code: 1), phase: .readingConnection))
        #expect(parse.kind == .invalidConnectionFile)
        #expect(parse.recovery == .chooseMachine)
    }
}
