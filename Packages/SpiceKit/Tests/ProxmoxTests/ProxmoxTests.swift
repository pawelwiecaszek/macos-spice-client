import Testing
@testable import Proxmox
import VVFile
import SpiceTransport

@Suite("Proxmox")
struct ProxmoxTests {
    @Test func vmRefFromProxmoxConnectionFile() throws {
        let file = try VVFileParser.parse("""
        [virt-viewer]
        type=spice
        host=pvespiceproxy:6512a3b4:101:pve-node1::0a2bc3d4e5f6
        proxy=http://pve1.example.com:3128
        tls-port=61000
        """)
        let ref = try #require(ProxmoxVMRef(profile: file.profile))
        #expect(ref == ProxmoxVMRef(apiHost: "pve1.example.com", node: "pve-node1", vmid: 101))
    }

    /// Proxmox returns `ca` from `…/spiceproxy` with newlines already escaped as `\n`
    /// (PVE::AccessControl::remote_viewer_config); the converted file must still yield a
    /// multi-line PEM, not one with literal backslash-n sequences.
    @Test func spiceproxyCAIsNotDoubleEscaped() throws {
        let pem = """
        -----BEGIN CERTIFICATE-----
        MIIBeDCCAR+gAwIBAgIUDp+YVJVvh1Fw0ZEbH/G9VA3cgK8wCgYIKoZIzj0EAwIw
        EjEQMA4GA1UEAwwHVGVzdCBDQTAeFw0yNjExMTkwOTExNTFaFw0zNjExMTYwOTEx
        NTFaMBIxEDAOBgNVBAMMB1Rlc3QgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNC
        AASSXnKHJDUk8i1cHPBs0mGPHQGpYOkJ6/tmi0INa2CrNKZAR461rUVlvB/xFmGr
        cAFISfNr3YW0gd8DNwI49sxdo1MwUTAdBgNVHQ4EFgQUr9+/zRAE/+h3PRIM/CCb
        46kIVT0wHwYDVR0jBBgwFoAUr9+/zRAE/+h3PRIM/CCb46kIVT0wDwYDVR0TAQH/
        BAUwAwEB/zAKBggqhkjOPQQDAgNHADBEAiAYIXQ2pZFhJ6l0qphfL3unOUA0TfOA
        TTRonKWSuzc2WQIgKQ8DpYaylXg7AG7BqS3BoKvvXQFM2yVRqTcTFmdLQw0=
        -----END CERTIFICATE-----

        """
        let apiValue = pem.replacingOccurrences(of: "\n", with: "\\n")  // as Proxmox sends it
        let text = ProxmoxClient.connectionFileText(from: [
            "type": "spice", "host": "pvespiceproxy:abc:101:pve-node1::def",
            "proxy": "http://pve1.example.com:3128", "tls-port": 61000, "ca": apiValue,
        ])
        let file = try VVFileParser.parse(text)
        #expect(file.profile.caPEM == pem)
        let certificates = PEM.certificates(in: try #require(file.profile.caPEM))
        #expect(certificates.count == 1)
        #expect(X509.subject(ofCertificate: try #require(certificates.first)) != nil)
    }

    @Test func plainQemuFileHasNoVM() throws {
        let file = try VVFileParser.parse("[virt-viewer]\ntype=spice\nhost=10.0.0.5\nport=5900\n")
        #expect(ProxmoxVMRef(profile: file.profile) == nil)
    }

    @Test func tokenValidation() {
        #expect(ProxmoxServer.isValidTokenID("root@pam!spice"))
        #expect(ProxmoxServer.isValidTokenID("pawel@pve!mac-client"))
        #expect(!ProxmoxServer.isValidTokenID("root@pam"))
        #expect(!ProxmoxServer.isValidTokenID("root@pam!x\r\nX-Evil: 1"))
        #expect(!ProxmoxServer.isValidTokenID("root@pam!a=b"))
        #expect(ProxmoxServer.isValidSecret("5f0e6c6e-2a3b-4c5d-8e9f-0a1b2c3d4e5f"))
        #expect(!ProxmoxServer.isValidSecret("not-a-uuid"))
    }

    @Test func qmpTimeoutIsRecognised() {
        #expect(ProxmoxClient.isQMPTimeout("VM 118 qmp command 'query-spice' failed - got timeout"))
        #expect(!ProxmoxClient.isQMPTimeout("VM 118 not running"))
    }

    @Test func fingerprintFormatting() {
        #expect(ProxmoxError.formatted("ab01cd") == "AB:01:CD")
    }

    #if canImport(Security)
    @Test func clientRejectsUnsafeSettings() {
        let bad = ProxmoxServer(name: "x", host: "evil/path", tokenID: "root@pam!t")
        #expect(throws: ProxmoxError.self) { try ProxmoxClient(server: bad, secret: "5f0e6c6e-2a3b-4c5d-8e9f-0a1b2c3d4e5f") }
        let good = ProxmoxServer(name: "x", host: "pve.example.com", tokenID: "root@pam!t")
        #expect(throws: ProxmoxError.self) { try ProxmoxClient(server: good, secret: "nope") }
    }
    #endif
}
