import Foundation
import Testing
@testable import SpiceTransport
import SpiceWire

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/tls/\(name)"))
}

/// Returns 128 bytes so tests don't need real RSA.
struct FakeEncryptor: TicketEncryptor {
    func encrypt(_ plaintext: [UInt8], subjectPublicKeyInfo: [UInt8]) throws -> [UInt8] {
        Array(plaintext.prefix(128)) + [UInt8](repeating: 0, count: 128 - min(128, plaintext.count))
    }
}

/// Minimal server side of the link handshake.
enum FakeLinkServer {
    static func serve(_ stream: MemoryByteStream, linkError: LinkError = .ok, authResult: LinkError = .ok,
                      offerMiniHeader: Bool = true) async throws -> (LinkMessage, [UInt8]) {
        let header = try LinkHeader(decoding: try await stream.receive(exactly: 16))
        let body = try await stream.receive(exactly: Int(header.bodySize))
        var r = ByteReader(body)
        let connectionID = try r.readU32()
        let type = ChannelType(rawValue: try r.readU8()) ?? .main
        let id = try r.readU8()
        let message = LinkMessage(connectionID: connectionID, channelType: type, channelID: id,
                                  commonCaps: CapabilitySet(), channelCaps: CapabilitySet())

        var reply = ByteWriter()
        reply.writeU32(linkError.rawValue)
        reply.writeBytes([UInt8](repeating: 0, count: 162))
        reply.writeU32(1)
        reply.writeU32(0)
        reply.writeU32(4 + 162 + 12)
        var caps = CapabilitySet(bits: [CommonCapability.protocolAuthSelection.rawValue, CommonCapability.authSpice.rawValue])
        if offerMiniHeader { caps.insert(CommonCapability.miniHeader.rawValue) }
        reply.writeU32(caps.words[0])
        var out = ByteWriter()
        out.writeU32(spiceMagic)
        out.writeU32(2)
        out.writeU32(2)
        out.writeU32(UInt32(reply.count))
        out.writeBytes(reply.bytes)
        try await stream.send(out.bytes)
        guard linkError == .ok, offerMiniHeader else { return (message, []) }

        var mechanism = ByteReader(try await stream.receive(exactly: 4))
        #expect(try mechanism.readU32() == UInt32(CommonCapability.authSpice.rawValue))
        let ticket = try await stream.receive(exactly: 128)
        var result = ByteWriter()
        result.writeU32(authResult.rawValue)
        try await stream.send(result.bytes)
        return (message, ticket)
    }
}

@Suite("Transport")
struct TransportTests {
    @Test func linkAndAuthenticate() async throws {
        let (client, server) = await MemoryByteStream.pair()
        async let served = FakeLinkServer.serve(server)
        let message = LinkMessage(connectionID: 42, channelType: .inputs, channelID: 0,
                                  commonCaps: ChannelLinker.clientCommonCaps, channelCaps: CapabilitySet())
        let linked = try await ChannelLinker.link(stream: client, message: message, ticket: Array("secret".utf8),
                                                  encryptor: FakeEncryptor())
        let (seen, ticket) = try await served
        #expect(seen.connectionID == 42)
        #expect(seen.channelType == .inputs)
        #expect(Array(ticket.prefix(7)) == Array("secret".utf8) + [0], "ticket must be NUL-terminated")
        #expect(linked.serverCommonCaps.contains(CommonCapability.miniHeader.rawValue))
    }

    @Test func expiredTicketMapsToAuthenticationFailure() async throws {
        let (client, server) = await MemoryByteStream.pair()
        async let served = FakeLinkServer.serve(server, authResult: .permissionDenied)
        let message = LinkMessage(connectionID: 0, channelType: .main, channelID: 0,
                                  commonCaps: ChannelLinker.clientCommonCaps, channelCaps: CapabilitySet())
        await #expect(throws: TransportError.authenticationFailed(.permissionDenied)) {
            try await ChannelLinker.link(stream: client, message: message, ticket: [], encryptor: FakeEncryptor())
        }
        _ = try await served
        #expect(TransportError.authenticationFailed(.permissionDenied).errorDescription?.contains("connection file") == true)
    }

    @Test func linkRejectedAndMissingMiniHeader() async throws {
        let message = LinkMessage(connectionID: 0, channelType: .main, channelID: 0,
                                  commonCaps: ChannelLinker.clientCommonCaps, channelCaps: CapabilitySet())
        do {
            let (client, server) = await MemoryByteStream.pair()
            async let served = FakeLinkServer.serve(server, linkError: .needSecured)
            await #expect(throws: TransportError.linkRejected(.needSecured)) {
                try await ChannelLinker.link(stream: client, message: message, ticket: [], encryptor: FakeEncryptor())
            }
            _ = try await served
        }
        do {
            let (client, server) = await MemoryByteStream.pair()
            async let served = FakeLinkServer.serve(server, offerMiniHeader: false)
            await #expect(throws: TransportError.self) {
                try await ChannelLinker.link(stream: client, message: message, ticket: [], encryptor: FakeEncryptor())
            }
            _ = try await served
        }
    }

    @Test func ticketLengthLimit() async throws {
        let (client, _) = await MemoryByteStream.pair()
        let message = LinkMessage(connectionID: 0, channelType: .main, channelID: 0,
                                  commonCaps: CapabilitySet(), channelCaps: CapabilitySet())
        await #expect(throws: TransportError.ticketTooLong) {
            try await ChannelLinker.link(stream: client, message: message, ticket: [UInt8](repeating: 65, count: 61),
                                         encryptor: FakeEncryptor())
        }
    }

    @Test func spkiToPKCS1() throws {
        let spki = Array(try fixture("ticket-key.spki.der"))
        let pkcs1 = Array(try fixture("ticket-key.pkcs1.der"))
        #expect(spki.count == spiceTicketPublicKeyBytes)
        #expect(X509.rsaPublicKey(fromSubjectPublicKeyInfo: spki) == pkcs1)
        #expect(X509.rsaPublicKey(fromSubjectPublicKeyInfo: [0x30, 0x81]) == nil)
    }

    @Test func certificateSubjectMatchesHostSubject() throws {
        let pem = String(decoding: try fixture("test-server.pem"), as: UTF8.self)
        let certificates = PEM.certificates(in: pem)
        #expect(certificates.count == 1)
        let subject = try #require(X509.subject(ofCertificate: certificates[0]))
        #expect(subject.map(\.type) == ["O", "OU", "CN"])

        let expected = try #require(HostSubject.parse("OU=PVE Cluster Node, O=Proxmox Virtual Environment,CN=pve-test.example.invalid"))
        #expect(HostSubject.matches(expected: expected, actual: subject))
        let wrong = try #require(HostSubject.parse("OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=other"))
        #expect(!HostSubject.matches(expected: wrong, actual: subject))
    }

    @Test func pemFromEscapedVVValue() {
        // The .vv parser unescapes \n; multiple certificates are supported.
        let block = "-----BEGIN CERTIFICATE-----\nAAEC\n-----END CERTIFICATE-----\n"
        #expect(PEM.certificates(in: block + block) == [[0, 1, 2], [0, 1, 2]])
        #expect(PEM.certificates(in: "garbage").isEmpty)
    }

    @Test func hostSubjectEscapedComma() throws {
        let parsed = try #require(HostSubject.parse("CN=a\\,b,O=x"))
        #expect(parsed == [X509.NameAttribute(type: "CN", value: "a,b"), X509.NameAttribute(type: "O", value: "x")])
        #expect(HostSubject.parse("no-equals") == nil)
    }

    @Test func routes() throws {
        let both = SpiceEndpoint(host: "h", port: 5900, tlsPort: 5901)
        #expect(try both.route(for: .display) == .init(port: 5901, useTLS: true))
        var partial = both
        partial.secureChannels = .some([.main])
        #expect(try partial.route(for: .main) == .init(port: 5901, useTLS: true))
        #expect(try partial.route(for: .display) == .init(port: 5900, useTLS: false))
        #expect(try SpiceEndpoint(host: "h", port: 5900).route(for: .main) == .init(port: 5900, useTLS: false))
        #expect(try SpiceEndpoint(host: "h", tlsPort: 61000).route(for: .cursor) == .init(port: 61000, useTLS: true))
        #expect(throws: TransportError.noRoute) { try SpiceEndpoint(host: "h").route(for: .main) }
    }

    /// Audit finding 1: `secure-channels` must never be downgraded to plain TCP.
    @Test func tlsRequirementIsNeverDowngraded() throws {
        let all = SpiceEndpoint(host: "h", port: 5900, secureChannels: .all)
        for channel in [ChannelType.main, .display, .inputs, .usbredir, .smartcard] {
            #expect(throws: TransportError.self) { try all.route(for: channel) }
        }
        let some = SpiceEndpoint(host: "h", port: 5900, secureChannels: .some([.main, .inputs]))
        #expect(throws: TransportError.self) { try some.route(for: .main) }
        #expect(throws: TransportError.self) { try some.route(for: .inputs) }
        #expect(try some.route(for: .display) == .init(port: 5900, useTLS: false))
        // The NEED_SECURED fallback only ever goes to a TLS port.
        #expect(all.secureRoute() == nil)
    }

    /// Audit finding 8: the CONNECT target can't smuggle headers or extra requests.
    @Test func httpConnectRejectsInjection() {
        #expect(HTTPConnect.request(target: "host\r\nX-Evil: 1") == nil)
        #expect(HTTPConnect.request(target: "host HTTP/1.1") == nil)
        #expect(HTTPConnect.request(target: "a/b") == nil)
        #expect(HTTPConnect.request(target: "") == nil)
        #expect(HTTPConnect.request(target: "[fe80::1%25en0]:5900") != nil)
    }

    @Test func httpConnect() throws {
        let request = String(decoding: try #require(HTTPConnect.request(target: "pvespiceproxy:abc:101:node::tok:61000")), as: UTF8.self)
        #expect(request.hasPrefix("CONNECT pvespiceproxy:abc:101:node::tok:61000 HTTP/1.1\r\n"))
        let response = Array("HTTP/1.1 200 OK\r\nX: y\r\n\r\nTLS".utf8)
        #expect(HTTPConnect.headerEnd(in: response) == response.count - 3)
        #expect(HTTPConnect.statusCode(ofResponse: response) == 200)
        #expect(HTTPConnect.statusCode(ofResponse: Array("HTTP/1.0 403 Forbidden\r\n\r\n".utf8)) == 403)
        #expect(HTTPConnect.headerEnd(in: Array("HTTP/1.1 200".utf8)) == nil)
    }

    #if canImport(Security)
    @Test func securityEncryptorProducesRSA1024Ciphertext() throws {
        let spki = Array(try fixture("ticket-key.spki.der"))
        let ciphertext = try SecurityTicketEncryptor().encrypt(Array("ticket".utf8) + [0], subjectPublicKeyInfo: spki)
        #expect(ciphertext.count == 128)
    }
    #endif
}
