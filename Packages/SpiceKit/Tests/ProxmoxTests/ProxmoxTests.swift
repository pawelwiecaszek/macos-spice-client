import Testing
@testable import Proxmox
import VVFile

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
