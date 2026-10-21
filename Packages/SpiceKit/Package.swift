// swift-tools-version: 6.0
// SpiceKit — platform-agnostic SPICE protocol implementation (no AppKit/SwiftUI).
//
// Pure modules (VVFile, SpiceWire, SpiceCodecs, USBRedirWire) also build and test on
// Linux, which keeps them easy to fuzz in CI. Darwin-only code (Network.framework,
// Security.framework, IOKit, CryptoTokenKit) is guarded with `#if canImport(...)`.

import PackageDescription

let strictSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "SpiceKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SpiceKit", targets: ["SpiceKit"]),
    ],
    targets: [
        // MARK: Pure modules (bytes in → values out)
        .target(name: "USBRedirWire", swiftSettings: strictSettings),
        .target(name: "VVFile", dependencies: ["USBRedirWire"], swiftSettings: strictSettings),
        .target(name: "SpiceWire", swiftSettings: strictSettings),
        .target(name: "SpiceCodecs", dependencies: ["SpiceWire"], swiftSettings: strictSettings),

        // MARK: I/O and state
        .target(name: "SpiceTransport", dependencies: ["SpiceWire"], swiftSettings: strictSettings),
        .target(name: "SpiceAgent", dependencies: ["SpiceWire"], swiftSettings: strictSettings),
        .target(
            name: "SpiceChannels",
            dependencies: ["SpiceWire", "SpiceCodecs", "SpiceTransport", "SpiceAgent", "USBRedirWire"],
            swiftSettings: strictSettings
        ),
        .target(name: "USBHost", dependencies: ["USBRedirWire"], swiftSettings: strictSettings),
        .target(name: "USBEmulation", dependencies: ["USBRedirWire"], swiftSettings: strictSettings),
        .target(name: "AudioHost", swiftSettings: strictSettings),
        .target(name: "Proxmox", dependencies: ["SpiceTransport", "VVFile"], swiftSettings: strictSettings),
        .target(name: "SmartcardHost", dependencies: ["SpiceChannels", "USBEmulation"], swiftSettings: strictSettings),

        // MARK: Public façade
        .target(
            name: "SpiceKit",
            dependencies: [
                "VVFile", "SpiceWire", "SpiceCodecs", "SpiceTransport",
                "SpiceChannels", "SpiceAgent", "USBRedirWire", "USBEmulation", "USBHost", "SmartcardHost", "Proxmox", "AudioHost",
            ],
            swiftSettings: strictSettings
        ),

        // MARK: Tests (fixtures live in Tests/Fixtures and are located via #filePath)
        .testTarget(name: "VVFileTests", dependencies: ["VVFile"]),
        .testTarget(name: "USBRedirWireTests", dependencies: ["USBRedirWire"]),
        .testTarget(name: "USBEmulationTests", dependencies: ["USBEmulation", "USBRedirWire"]),
        .testTarget(name: "SpiceWireTests", dependencies: ["SpiceWire"]),
        .testTarget(name: "SpiceCodecsTests", dependencies: ["SpiceCodecs", "SpiceWire"]),
        .testTarget(name: "SpiceTransportTests", dependencies: ["SpiceTransport", "SpiceWire"]),
        .testTarget(name: "SpiceKitTests", dependencies: ["SpiceKit"]),
        .testTarget(name: "ProxmoxTests", dependencies: ["Proxmox", "VVFile"]),
        .testTarget(name: "AudioHostTests", dependencies: ["AudioHost"]),
        .testTarget(
            name: "SpiceChannelsTests",
            dependencies: ["SpiceChannels", "SpiceWire", "SpiceCodecs", "SpiceTransport", "USBRedirWire", "SpiceAgent"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
