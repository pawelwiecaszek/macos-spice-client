import Foundation
import Testing
@testable import Ravada

struct RavadaConnectTests {
    @Test func rebootHasFixedNonForceRouteAndIndependentMetadataPermission() throws {
        let endpoint = try RavadaEndpoint(portalURL: #require(URL(string: "https://portal.example.invalid:8443/vdi/")))
        let request = RavadaBrokerRequest.reboot(42)
        let url = try request.url(using: endpoint)
        #expect(url.absoluteString == "https://portal.example.invalid:8443/vdi/machine/reboot/42.json")
        #expect(url.query == nil && request.isMutation)
        #expect(request.uncertainMutationError == .ambiguousReboot)
        #expect(throws: RavadaBrokerError.invalidResponse) { try RavadaBrokerRequest.reboot(0).url(using: endpoint) }
        for (field, expected) in [("", nil), (#", "can_reboot":true"#, true),
                                  (#", "can_reboot":0"#, false), (#", "can_reboot":"future""#, nil)] as [(String, Bool?)] {
            let info = try response("{\"id\":42,\"is_active\":1,\"is_base\":0,\"requests\":0,\"can_shutdown\":1,\"hardware\":{\"display\":[]}\(field)}").decode(RavadaMachineInfo.self)
            #expect(info.canShutdown == true && info.canReboot == expected)
        }
    }
    @Test func shutdownUsesOnlyFixedNonForceRouteAndItsOwnUncertainOutcome() throws {
        let endpoint = try RavadaEndpoint(portalURL: #require(URL(string: "https://portal.example.invalid:8443/vdi/")))
        let url = try RavadaBrokerRequest.shutdown(42).url(using: endpoint)
        #expect(url.absoluteString == "https://portal.example.invalid:8443/vdi/machine/shutdown/42.json")
        #expect(url.query == nil)
        #expect(RavadaBrokerRequest.shutdown(42).isMutation)
        #expect(RavadaBrokerRequest.shutdown(42).uncertainMutationError == .ambiguousShutdown)
        #expect(RavadaBrokerRequest.start(42).uncertainMutationError == .ambiguousStart)
        for id in [0, -1] {
            #expect(throws: RavadaBrokerError.invalidResponse) { try RavadaBrokerRequest.shutdown(id).url(using: endpoint) }
        }
    }

    @Test func shutdownMetadataPreservesUnknownPermissionAndVolatility() throws {
        func info(_ flags: String) throws -> RavadaMachineInfo {
            try response("{\"id\":42,\"is_active\":1,\"is_base\":0,\"requests\":0,\"hardware\":{\"display\":[]},\(flags)}").decode(RavadaMachineInfo.self)
        }
        let permitted = try info(#""can_shutdown":"1","is_volatile":"""#)
        #expect(permitted.canShutdown == true && permitted.isVolatile == false)
        let denied = try info(#""can_shutdown":0,"is_volatile":true"#)
        #expect(denied.canShutdown == false && denied.isVolatile == true)
        let unknown = try info(#""can_shutdown":"future","is_volatile":2"#)
        #expect(unknown.canShutdown == nil && unknown.isVolatile == nil)
    }
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
