import Foundation
import Testing
import USBRedirWire
@testable import VVFile

private func fixture(_ name: String) throws -> [UInt8] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/vv/\(name)")
    return Array(try Data(contentsOf: url))
}

@Suite("VVFile parser")
struct VVFileParserTests {
    @Test func proxmoxFile() throws {
        let file = try VVFileParser.parse(try fixture("proxmox.vv"))
        let profile = file.profile
        #expect(profile.host == "pvespiceproxy:00000000:101:pve-test::0000000000000000000000000000000000000000")
        #expect(profile.port == nil)
        #expect(profile.tlsPort == 61000)
        #expect(profile.proxy == ProxyEndpoint(host: "pve-test.example.invalid", port: 3128))
        #expect(profile.hostSubject == "OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve-test.example.invalid")
        #expect(profile.caPEM == "-----BEGIN CERTIFICATE-----\nTUlJRkFLRUZBS0VGQUtF\n-----END CERTIFICATE-----\n")
        #expect(profile.deleteThisFile)
        #expect(profile.title == "VM 101 - test-vm")
        #expect(profile.toggleFullscreenHotkey == Hotkey(modifiers: [.shift], key: "F11"))
        #expect(profile.releaseCursorHotkey == Hotkey(modifiers: [.control, .alt], key: "R"))
        #expect(profile.secureAttentionHotkey == Hotkey(modifiers: [.control, .alt], key: "Insert"))
        #expect(profile.secureChannels.requiresTLS(.main))
        #expect(profile.secureChannels.requiresTLS(.usbredir))
        #expect(!profile.secureChannels.requiresTLS(.webdav))
        let ticket = profile.password?.withBytes { $0.map { String(decoding: $0, as: UTF8.self) } }
        #expect(ticket == "not-a-real-ticket-0123456789")
        #expect(file.warnings.isEmpty)
    }

    @Test func ticketIsRedactedAndWipeable() throws {
        let profile = try VVFileParser.parse(try fixture("proxmox.vv")).profile
        let ticket = try #require(profile.password)
        #expect(!"\(ticket)".contains("ticket-0123"))
        #expect(!"\(profile)".contains("ticket-0123"))
        ticket.wipe()
        #expect(ticket.isWiped)
        #expect(ticket.withBytes { $0 } == nil)
    }

    @Test func plainQemu() throws {
        let file = try VVFileParser.parse(try fixture("plain-qemu.vv"))
        #expect(file.profile.host == "127.0.0.1")
        #expect(file.profile.port == 5930)
        #expect(file.profile.tlsPort == nil)
        #expect(file.profile.password == nil)
        #expect(file.profile.fullscreen == false)
        #expect(file.profile.secureChannels == .unspecified)
        #expect(file.profile.displayTitle == "SPICE")
    }

    @Test func crlfBomDuplicatesUnknownKeys() throws {
        let file = try VVFileParser.parse(try fixture("crlf-bom.vv"))
        let profile = file.profile
        #expect(profile.host == "example.invalid")
        #expect(profile.port == 5900)
        #expect(profile.tlsPort == 5901)
        #expect(profile.title == "second")
        #expect(profile.unknownKeys["future-key"] == "whatever")
        #expect(profile.enableUSBRedirection == true)
        #expect(profile.enableUSBAutoshare)
        #expect(profile.colorDepth == 24)
        #expect(profile.disableEffects == ["wallpaper", "font-smooth"])
        #expect(profile.versions == "rhev-win64:2.0-160;rhev-win32:2.0-160")
        #expect(file.warnings.contains(.duplicateKey("title", line: 9)))
        #expect(file.warnings.contains(.unknownKey("future-key")))

        let filter = try #require(profile.usbFilter)
        #expect(filter.rules.count == 3)
        let hid = USBFilter.Device(classes: [0x03], vendorID: 0x046D, productID: 0xC52B, deviceVersion: 0x1200)
        let sandisk = USBFilter.Device(classes: [0x08], vendorID: 0x0781, productID: 0x5581, deviceVersion: 0x0100)
        let other = USBFilter.Device(classes: [0x08], vendorID: 0x1234, productID: 0x0001, deviceVersion: 0x0100)
        #expect(!filter.allows(hid))
        #expect(filter.allows(sandisk))
        #expect(!filter.allows(other))
    }

    @Test func ovirtSectionIgnoredAndGtkHotkeys() throws {
        let file = try VVFileParser.parse(try fixture("ovirt.vv"))
        #expect(file.profile.host == "192.0.2.10")
        #expect(file.profile.port == nil, "port=-1 means unset")
        #expect(file.profile.tlsPort == 5901)
        #expect(file.profile.secureChannels == .all)
        #expect(file.profile.releaseCursorHotkey == Hotkey(modifiers: [.shift], key: "F12"))
        #expect(file.profile.unknownKeys.isEmpty, "keys of [ovirt] must not leak into the profile")
    }

    @Test func rejectsOtherProtocols() throws {
        #expect(throws: VVFileError.unsupportedProtocol("vnc")) {
            try VVFileParser.parse(try fixture("vnc.vv"))
        }
    }

    @Test(arguments: [
        ("", VVFileError.missingVirtViewerSection),
        ("[other]\ntype=spice\n", .missingVirtViewerSection),
        ("[virt-viewer]\nhost=a\nport=1\n", .missingKey("type")),
        ("[virt-viewer]\ntype=spice\nport=1\n", .missingKey("host")),
        ("[virt-viewer]\ntype=spice\nhost=a\n", .noPort),
        ("[virt-viewer]\ntype=spice\nhost=a\nport=99999\n", .invalidValue(key: "port")),
        ("[virt-viewer]\ntype=spice\nhost=a\nport=1\nproxy=socks5://p:1\n", .invalidValue(key: "proxy")),
        // Audit finding 8: escaped CR/LF or spaces in the host would reach the CONNECT line.
        ("[virt-viewer]\ntype=spice\nhost=a\\r\\nX-Evil: 1\nport=1\n", .invalidValue(key: "host")),
        ("[virt-viewer]\ntype=spice\nhost=a\\sb\nport=1\n", .invalidValue(key: "host")),
        ("[virt-viewer]\ntype=spice\nhost=a\nport=1\nproxy=http://p\\r\\nX:1:3128\n", .invalidValue(key: "proxy")),
        // Re-audit 1: a misspelt or empty secure-channels must not quietly downgrade channels.
        ("[virt-viewer]\ntype=spice\nhost=a\nport=1\ntls-port=2\nsecure-channels=main;dispay\n", .invalidValue(key: "secure-channels")),
        ("[virt-viewer]\ntype=spice\nhost=a\nport=1\ntls-port=2\nsecure-channels=;\n", .invalidValue(key: "secure-channels")),
    ])
    func errors(input: String, expected: VVFileError) {
        #expect(throws: expected) { try VVFileParser.parse(input) }
    }

    /// Audit finding 7: an unreadable usb-filter disables redirection instead of allowing all.
    @Test func invalidUSBFilterDisablesRedirection() throws {
        let file = try VVFileParser.parse("[virt-viewer]\ntype=spice\nhost=h\nport=1\nusb-filter=not,a,filter\n")
        #expect(file.profile.usbFilter == nil)
        #expect(file.profile.enableUSBRedirection == false)
        #expect(file.warnings.contains(.invalidOptionalValue(key: "usb-filter")))
    }

    @Test func rejectsInvalidUTF8() {
        #expect(throws: VVFileError.notUTF8) { try VVFileParser.parse([0x5B, 0xFF, 0xFE, 0x5D]) }
    }

    @Test func malformedLinesAreWarnings() throws {
        let file = try VVFileParser.parse("garbage\n[virt-viewer]\ntype=spice\nnot a pair\nhost=h\nport=1\n[broken\n")
        #expect(file.profile.host == "h")
        #expect(file.warnings.contains(.malformedLine(line: 1)))
        #expect(file.warnings.contains(.malformedLine(line: 4)))
        #expect(file.warnings.contains(.malformedLine(line: 7)))
    }

    @Test func unescape() {
        let (value, ok) = ValueReader_unescape("a\\nb\\tc\\sd\\\\e")
        #expect(value == "a\nb\tc d\\e")
        #expect(ok)
        #expect(ValueReader_unescape("bad\\q").1 == false)
        #expect(ValueReader_unescape("trailing\\").1 == false)
    }

    @Test(arguments: [
        ("http://proxy.example:3128", ProxyEndpoint(host: "proxy.example", port: 3128)),
        ("http://proxy.example", ProxyEndpoint(host: "proxy.example", port: 3128)),
        ("proxy.example:8080", ProxyEndpoint(host: "proxy.example", port: 8080)),
        ("http://user:pw@proxy.example:81/", ProxyEndpoint(host: "proxy.example", port: 81)),
        ("http://[2001:db8::1]:3128", ProxyEndpoint(host: "2001:db8::1", port: 3128)),
    ])
    func proxies(input: String, expected: ProxyEndpoint) {
        #expect(ValueReader_parseProxy(input) == expected)
    }

    @Test(arguments: [
        ("Ctrl+Alt+Del", Hotkey(modifiers: [.control, .alt], key: "Delete")),
        ("shift+f11", Hotkey(modifiers: [.shift], key: "F11")),
        ("<Control><Alt>r", Hotkey(modifiers: [.control, .alt], key: "R")),
        ("Super+PgUp", Hotkey(modifiers: [.super], key: "PageUp")),
    ])
    func hotkeys(input: String, expected: Hotkey) {
        #expect(Hotkey(parsing: input) == expected)
    }

    @Test(arguments: ["", "Ctrl+", "Hyperdrive+R", "Ctrl+Alt+NoSuchKey", "F25"])
    func invalidHotkeys(input: String) {
        #expect(Hotkey(parsing: input) == nil)
    }

    /// Cheap deterministic fuzzing: random mutations of the fixtures must never crash.
    @Test func fuzzMutationsNeverCrash() throws {
        let seeds = try ["proxmox.vv", "plain-qemu.vv", "crlf-bom.vv", "ovirt.vv"].map(fixture)
        var rng = SplitMix64(seed: 0x5EED)
        for _ in 0..<4000 {
            var bytes = seeds[Int(rng.next() % UInt64(seeds.count))]
            let mutations = 1 + Int(rng.next() % 8)
            for _ in 0..<mutations where !bytes.isEmpty {
                let index = Int(rng.next() % UInt64(bytes.count))
                switch rng.next() % 4 {
                case 0: bytes[index] = UInt8(truncatingIfNeeded: rng.next())
                case 1: bytes.remove(at: index)
                case 2: bytes.insert(UInt8(truncatingIfNeeded: rng.next()), at: index)
                default: bytes.insert(contentsOf: [0x5C, 0x0A, 0x3D, 0x5B], at: index)
                }
            }
            _ = try? VVFileParser.parse(bytes)
        }
    }

    /// Audit: the plaintext warning must also cover partially encrypted sessions.
    @Test func plaintextExposure() {
        var profile = ConnectionProfile(host: "h")
        profile.port = 5900
        #expect(profile.plaintextExposure == .unencrypted)
        profile.secureChannels = .all
        #expect(profile.plaintextExposure == .encrypted)  // refused, never downgraded

        profile.tlsPort = 5901
        profile.secureChannels = .unspecified
        #expect(profile.plaintextExposure == .encrypted)
        profile.secureChannels = .some([.main, .inputs])
        guard case .partial(let plain) = profile.plaintextExposure else {
            Issue.record("expected partial exposure"); return
        }
        #expect(plain.contains(.display) && !plain.contains(.main) && !plain.contains(.inputs))
        profile.secureChannels = .some(Set(ChannelName.allCases))
        #expect(profile.plaintextExposure == .encrypted)

        profile.port = nil
        profile.secureChannels = .some([.main])
        #expect(profile.plaintextExposure == .encrypted)
    }
}

// Expose private helpers for testing without widening their access level in the module.
private func ValueReader_unescape(_ text: String) -> (String, Bool) {
    VVFileTesting.unescape(text)
}

private func ValueReader_parseProxy(_ text: String) -> ProxyEndpoint? {
    VVFileTesting.parseProxy(text)
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
