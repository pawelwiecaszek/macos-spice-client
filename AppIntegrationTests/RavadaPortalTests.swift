import Foundation
import Testing
@testable import SpiceClient

struct RavadaPortalTests {
    @Test func portalAddressesRequireHTTPSAndNoEmbeddedCredentials() throws {
        let portal = try #require(RavadaPortalConfiguration.portalURL(" https://vdi.example.invalid/ravada/ "))
        #expect(portal.absoluteString == "https://vdi.example.invalid/ravada/")
        for address in ["http://vdi.example.invalid", "https://user:secret@vdi.example.invalid",
                        "file:///tmp/guest.vv", "https://vdi.example.invalid/#fragment",
                        "https://vdi.example.invalid:0", "https://vdi.example.invalid:65536", ""] {
            #expect(RavadaPortalConfiguration.portalURL(address) == nil)
        }
    }

    @Test func downloadsCannotCrossOriginOrDowngradeTLS() throws {
        let portal = try #require(URL(string: "https://vdi.example.invalid/ravada/"))
        #expect(RavadaPortalConfiguration.sameOrigin(URL(string: "https://VDI.example.invalid:443/guest.vv"), as: portal))
        for address in ["http://vdi.example.invalid/guest.vv", "https://vdi.example.invalid:8443/guest.vv",
                        "https://other.example.invalid/guest.vv", "https://vdi.example.invalid.evil.invalid/guest.vv",
                        "https://user:secret@vdi.example.invalid/guest.vv"] {
            #expect(!RavadaPortalConfiguration.sameOrigin(URL(string: address), as: portal))
        }
    }

    @Test func recognizesInlineMIMEAndTLSConnectionFilenames() throws {
        let url = try #require(URL(string: "https://vdi.example.invalid/machine/display"))
        let inline = URLResponse(url: url, mimeType: "application/x-virt-viewer",
                                 expectedContentLength: -1, textEncodingName: "utf-8")
        #expect(RavadaPortalConfiguration.isConnectionFile(inline))
        let generic = URLResponse(url: url, mimeType: "application/octet-stream",
                                  expectedContentLength: 20, textEncodingName: nil)
        #expect(RavadaPortalConfiguration.isConnectionFile(generic, filename: "42.tls.vv"))
        #expect(!RavadaPortalConfiguration.isConnectionFile(generic, filename: "report.pdf"))
    }

    @Test func downloadedFilesUseTheExistingParserAndSizeLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("[virt-viewer]\ntype=spice\nhost=example.invalid\nport=5930\n".utf8).write(to: url)
        let profile = try RavadaPortalModel.readConnectionFile(at: url)
        #expect(profile.host == "example.invalid")
        #expect(profile.port == 5930)
        try Data("[virt-viewer]\ntype=vnc\nhost=example.invalid\nport=5900\n".utf8).write(to: url)
        #expect(throws: (any Error).self) { try RavadaPortalModel.readConnectionFile(at: url) }
        try Data(repeating: 65, count: 1024 * 1024 + 1).write(to: url)
        #expect(throws: (any Error).self) { try RavadaPortalModel.readConnectionFile(at: url) }
    }

    @Test func downloadPolicyInterruptionIsNotAConnectionFailure() {
        #expect(RavadaPortalConfiguration.isExpectedNavigationCancellation(
            NSError(domain: "WebKitErrorDomain", code: 102)))
        #expect(RavadaPortalConfiguration.isExpectedNavigationCancellation(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        for error in [NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted),
                      NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost),
                      NSError(domain: "OtherDomain", code: 102),
                      NSError(domain: "OtherDomain", code: NSURLErrorCancelled)] {
            #expect(!RavadaPortalConfiguration.isExpectedNavigationCancellation(error))
        }
    }

    @Test func ravadaFullscreenHintStillOpensAWindow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("[virt-viewer]\ntype=spice\nhost=example.invalid\nport=5930\nfullscreen=1\n".utf8)
            .write(to: url)
        let profile = try RavadaPortalModel.readConnectionFile(at: url)
        #expect(!profile.fullscreen)
        if case .file(let file, _, _) = SessionWindowManager.read(url) {
            #expect(file.profile.fullscreen)
        } else { Issue.record("Manual file opening must still honor fullscreen hints") }
    }
}
