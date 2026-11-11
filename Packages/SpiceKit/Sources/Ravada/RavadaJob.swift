import Foundation

/// Accepted job identity returned by /machine/start/{id}.json.
public struct RavadaStartReceipt: Decodable, Sendable {
    public let req: Int
}

/// Request.info in v2.4.6 (lib/Ravada/Request.pm:371–389). Done alone is not success.
public struct RavadaJob: Decodable, Sendable {
    public let id: Int
    public let status: String
    public let idDomain: Int?
    private let error: String?
    enum CodingKeys: String, CodingKey { case id, status, error; case idDomain = "id_domain" }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        status = try values.decode(String.self, forKey: .status)
        idDomain = try values.decodeIfPresent(Int.self, forKey: .idDomain)
        if let text = try? values.decode(String.self, forKey: .error) { error = text.isEmpty ? nil : "failed" }
        else if let number = try? values.decode(Int.self, forKey: .error) { error = number == 0 ? nil : "failed" }
        else if (try? values.decodeNil(forKey: .error)) == true { error = nil }
        else { error = "unknown" }
    }

    /// Only a matching successful terminal request can authorize the next phase.
    public func isComplete(requestID: Int, machineID: Int) throws -> Bool {
        guard id == requestID, id > 0, error == nil,
              idDomain == nil || idDomain == machineID else { throw RavadaBrokerError.jobFailed }
        if status == "done" {
            guard idDomain == machineID else { throw RavadaBrokerError.jobFailed }
            return true
        }
        guard ["requested", "working", "waiting", "retry", "retrying", "starting"].contains(status) else {
            throw RavadaBrokerError.jobFailed
        }
        return false
    }
}

