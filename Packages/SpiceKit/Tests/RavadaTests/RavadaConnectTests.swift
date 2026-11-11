import Foundation
import Testing
@testable import Ravada

struct RavadaConnectTests {
    private func response(_ text: String) -> RavadaBrokerResponse {
        .init(data: Data(text.utf8), status: 200, contentType: "application/json")
    }

    @Test func fixedRoutesPreservePrefixAndRejectUnverifiedDrivers() throws {
        let endpoint = try RavadaEndpoint(portalURL: #require(URL(string: "https://portal.example.invalid/vdi/")))
        #expect(try RavadaBrokerRequest.start(42).url(using: endpoint).path == "/vdi/machine/start/42.json")
        #expect(try RavadaBrokerRequest.job(12).url(using: endpoint).path == "/vdi/request/12.json")
        #expect(try RavadaBrokerRequest.connection(machineID: 42, driver: "spice-tls", fileExtension: "tls.vv").url(using: endpoint).path == "/vdi/machine/display/spice-tls/42.tls.vv")
        #expect(RavadaBrokerRequest.start(42).isMutation)
        #expect(!RavadaBrokerRequest.job(12).isMutation)
        #expect(throws: RavadaBrokerError.invalidResponse) {
            try RavadaBrokerRequest.connection(machineID: 42, driver: "../start", fileExtension: "json").url(using: endpoint)
        }
        #expect(throws: RavadaBrokerError.invalidResponse) { try RavadaBrokerRequest.start(0).url(using: endpoint) }
    }

    @Test func jobNeedsMatchingSuccessfulTerminalIdentity() throws {
        let pending = try response(#"{"id":12,"status":"working","error":"","id_domain":42}"#).decode(RavadaJob.self)
        #expect(try !pending.isComplete(requestID: 12, machineID: 42))
        let done = try response(#"{"id":12,"status":"done","error":null,"id_domain":42}"#).decode(RavadaJob.self)
        #expect(try done.isComplete(requestID: 12, machineID: 42))
        for json in [#"{"id":13,"status":"done","error":"","id_domain":42}"#,
                     #"{"id":12,"status":"done","error":"","id_domain":43}"#,
                     #"{"id":12,"status":"done","error":"backend failure","id_domain":42}"#,
                     #"{"id":12,"status":"done","error":null,"id_domain":null}"#,
                     #"{"id":12,"status":"future-state","error":null,"id_domain":42}"#] {
            let job = try response(json).decode(RavadaJob.self)
            #expect(throws: RavadaBrokerError.jobFailed) { try job.isComplete(requestID: 12, machineID: 42) }
        }
    }

    @Test func machineMetadataPrefersAdvertisedTLSWithoutDowngrading() throws {
        let info = try response(#"{"id":42,"is_active":1,"is_base":0,"is_hibernated":0,"requests":0,"hardware":{"display":[{"driver":"spice","file_extension":"vv","is_active":1,"port":5900},{"driver":"spice-tls","file_extension":"tls.vv","is_active":0,"port":"5901"}]}}"#).decode(RavadaMachineInfo.self)
        #expect(info.preferredDisplay?.driver == "spice-tls")
        #expect(info.preferredDisplay?.isActive == false)
        #expect(info.preferredDisplay?.port == 5901)
    }

    @Test func malformedAdvertisedTLSNeverFallsBackToPlain() throws {
        let info = try response(#"{"id":42,"is_active":1,"is_base":0,"is_hibernated":0,"requests":0,"hardware":{"display":[{"driver":"spice","file_extension":"vv","is_active":1,"port":5900},{"driver":"spice-tls","is_active":0}]}}"#).decode(RavadaMachineInfo.self)
        #expect(info.preferredDisplay == nil)
    }

    @Test func errorAndHTMLResponsesNeverDecodeAsJobOrConnection() {
        for (status, mime, expected) in [(403, "application/json", RavadaBrokerError.permissionDenied),
                                         (200, "text/html", .signInRequired), (302, "text/html", .redirectRejected)] {
            let value = RavadaBrokerResponse(data: Data("synthetic error".utf8), status: status, contentType: mime)
            #expect(throws: expected) { try value.validate(mime: "application/x-virt-viewer") }
        }
    }
}
