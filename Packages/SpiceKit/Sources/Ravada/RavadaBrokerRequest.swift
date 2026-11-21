import Foundation

/// Only these release-verified broker routes are constructible. Start and shutdown
/// mutate despite using GET in Ravada 2.4.6; never replay them automatically.
public enum RavadaBrokerRequest: Equatable, Sendable {
    case catalog
    case machineInfo(Int)
    case start(Int)
    case shutdown(Int)
    case job(Int)
    case connection(machineID: Int, driver: String, fileExtension: String)

    public var isMutation: Bool { uncertainMutationError != nil }
    public var uncertainMutationError: RavadaBrokerError? {
        switch self {
        case .start: .ambiguousStart
        case .shutdown: .ambiguousShutdown
        default: nil
        }
    }

    public func url(using endpoint: RavadaEndpoint) throws -> URL {
        let path: String
        switch self {
        case .catalog: return endpoint.catalogURL
        case .machineInfo(let id): path = "machine/info/\(try valid(id)).json"
        case .start(let id): path = "machine/start/\(try valid(id)).json"
        case .shutdown(let id): path = "machine/shutdown/\(try valid(id)).json"
        case .job(let id): path = "request/\(try valid(id)).json"
        case .connection(let id, let driver, let ext):
            guard (driver == "spice-tls" && ext == "tls.vv") || (driver == "spice" && ext == "vv") else {
                throw RavadaBrokerError.invalidResponse
            }
            path = "machine/display/\(driver)/\(try valid(id)).\(ext)"
        }
        return endpoint.catalogURL.deletingLastPathComponent().appendingPathComponent(path)
    }

    private func valid(_ id: Int) throws -> Int {
        guard id > 0 else { throw RavadaBrokerError.invalidResponse }
        return id
    }
}

