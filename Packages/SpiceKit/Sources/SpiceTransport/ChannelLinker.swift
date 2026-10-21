import Foundation
import SpiceWire

/// Encrypts the SPICE ticket with the server's RSA-1024 key (OAEP, SHA-1).
public protocol TicketEncryptor: Sendable {
    /// - Parameters:
    ///   - plaintext: ticket bytes followed by a NUL terminator.
    ///   - subjectPublicKeyInfo: the 162-byte DER key from `SpiceLinkReply`.
    /// - Returns: 128 bytes of ciphertext.
    func encrypt(_ plaintext: [UInt8], subjectPublicKeyInfo: [UInt8]) throws -> [UInt8]
}

/// Outcome of a successful link + authentication.
public struct LinkedChannel: Sendable {
    public var serverCommonCaps: CapabilitySet
    public var serverChannelCaps: CapabilitySet
}

/// Performs the SPICE link handshake and ticket authentication on a connected stream.
///
/// Sequence (spice-protocol protocol.h):
/// 1. client → `SpiceLinkHeader` + `SpiceLinkMess` + caps
/// 2. server → `SpiceLinkHeader` + `SpiceLinkReply` (error, RSA key, caps)
/// 3. if `PROTOCOL_AUTH_SELECTION`: client → uint32 `SPICE_COMMON_CAP_AUTH_SPICE`
/// 4. client → RSA-OAEP(ticket + NUL), 128 bytes
/// 5. server → uint32 link result
public enum ChannelLinker {
    /// Common caps every channel advertises.
    public static let clientCommonCaps = CapabilitySet(bits: [
        CommonCapability.protocolAuthSelection.rawValue,
        CommonCapability.authSpice.rawValue,
        CommonCapability.miniHeader.rawValue,
    ])

    /// Upper bound on the link reply size we accept.
    static let maxReplySize: UInt32 = 64 * 1024

    public static func link(
        stream: any SpiceByteStream,
        message: LinkMessage,
        ticket: [UInt8],
        encryptor: any TicketEncryptor
    ) async throws -> LinkedChannel {
        guard ticket.count <= spiceMaxPasswordLength else { throw TransportError.ticketTooLong }
        try await stream.send(message.encode())

        let header = try LinkHeader(decoding: try await stream.receive(exactly: LinkHeader.size))
        guard header.magic == spiceMagic else { throw TransportError.protocolViolation("bad link magic") }
        guard header.major == spiceVersionMajor else {
            throw TransportError.unsupportedServer("protocol version \(header.major).\(header.minor)")
        }
        guard header.bodySize >= 4, header.bodySize <= maxReplySize else {
            throw TransportError.protocolViolation("link reply size \(header.bodySize)")
        }
        let body = try await stream.receive(exactly: Int(header.bodySize))

        // The error field comes first; a rejected link may omit the rest.
        var errorReader = ByteReader(body)
        let errorCode = try errorReader.readU32()
        if errorCode != LinkError.ok.rawValue {
            throw TransportError.linkRejected(LinkError(rawValue: errorCode) ?? .error)
        }
        let reply = try LinkReply(decoding: body)

        guard reply.commonCaps.contains(CommonCapability.miniHeader.rawValue) else {
            throw TransportError.unsupportedServer("server lacks SPICE_COMMON_CAP_MINI_HEADER")
        }
        if reply.commonCaps.contains(CommonCapability.protocolAuthSelection.rawValue) {
            guard reply.commonCaps.contains(CommonCapability.authSpice.rawValue) else {
                throw TransportError.unsupportedServer("only SASL authentication offered")
            }
            var writer = ByteWriter()
            writer.writeU32(UInt32(CommonCapability.authSpice.rawValue))
            try await stream.send(writer.bytes)
        }

        var plaintext = ticket
        plaintext.append(0)
        // Zeroed on every path, including encryption failure.
        defer { for index in plaintext.indices { plaintext[index] = 0 } }
        let ciphertext: [UInt8]
        do {
            ciphertext = try encryptor.encrypt(plaintext, subjectPublicKeyInfo: reply.publicKey)
        } catch {
            throw TransportError.encryptionFailed
        }
        guard ciphertext.count == spiceEncryptedTicketBytes else { throw TransportError.encryptionFailed }
        try await stream.send(ciphertext)

        var resultReader = ByteReader(try await stream.receive(exactly: 4))
        let result = try resultReader.readU32()
        guard result == LinkError.ok.rawValue else {
            throw TransportError.authenticationFailed(LinkError(rawValue: result) ?? .error)
        }
        return LinkedChannel(serverCommonCaps: reply.commonCaps, serverChannelCaps: reply.channelCaps)
    }
}

/// Builds and parses the HTTP CONNECT exchange used for `.vv` `proxy=` tunnels.
public enum HTTPConnect {
    /// `target` is passed verbatim (Proxmox uses opaque, colon-laden host strings), but
    /// only when it can't break out of the request line: `nil` for anything else.
    public static func request(target: String) -> [UInt8]? {
        guard isSafeTarget(target) else { return nil }
        return Array("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n".utf8)
    }

    /// Letters, digits and `-._~:[]%` only (host names, IPv6 literals, Proxmox tokens);
    /// no whitespace, control characters or delimiters such as `/`, `?`, `#`, `@`.
    public static func isSafeTarget(_ target: String) -> Bool {
        !target.isEmpty && target.utf8.count <= 1024 && target.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar) || "-._~:[]%".unicodeScalars.contains(scalar))
        }
    }

    /// Returns the index just past the header terminator, or `nil` if incomplete.
    public static func headerEnd(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4)
        where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            return i + 4
        }
        return nil
    }

    /// Parses the status code from `HTTP/1.x NNN reason`.
    public static func statusCode(ofResponse header: [UInt8]) -> Int? {
        guard let lineEnd = header.firstIndex(of: 13) else { return nil }
        let line = String(decoding: header[..<lineEnd], as: UTF8.self)
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let code = Int(parts[1]) else { return nil }
        return code
    }
}
