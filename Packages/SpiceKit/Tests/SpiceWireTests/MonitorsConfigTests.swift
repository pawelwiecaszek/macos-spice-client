import Testing
import SpiceWire

struct MonitorsConfigTests {
    @Test func decodesIndependentIDsCoordinatesAndUnknownFlags() throws {
        let heads = [
            MonitorHead(monitorID: 9, surfaceID: 3, width: 1280, height: 720,
                        x: 1920, y: 40, flags: 0x8000_0001),
            MonitorHead(monitorID: 2, surfaceID: 3, width: 1920, height: 1080,
                        x: 0, y: 0, flags: 0),
        ]
        let decoded = try MonitorsConfig(decoding: encode(heads, maxAllowed: 8))
        #expect(decoded.heads == heads)
        #expect(decoded.maxAllowed == 8)
    }

    @Test func preservesDisabledHeadsAndUnconstrainedWireValues() throws {
        let heads = [
            MonitorHead(monitorID: .max, surfaceID: .max, width: 0, height: 0,
                        x: .max, y: .max, flags: .max),
            MonitorHead(monitorID: 0, surfaceID: 0, width: 0, height: 1080,
                        x: 0, y: 0, flags: 0),
        ]
        // The schema does not define count <= max_allowed; preserve both fields.
        let decoded = try MonitorsConfig(decoding: encode(heads, maxAllowed: 0))
        #expect(decoded.heads == heads && decoded.maxAllowed == 0)
    }

    @Test func emptyConfigurationRequiresOnlyItsHeader() throws {
        let decoded = try MonitorsConfig(decoding: encode([], maxAllowed: 4))
        #expect(decoded.heads.isEmpty && decoded.maxAllowed == 4)
        #expect(throws: WireError.invalidValue("monitor config trailing bytes")) {
            try MonitorsConfig(decoding: [0, 0, 4, 0, 0])
        }
    }

    @Test func acceptsTheMetadataLimitAndRejectsCountsBeforeReadingRecords() throws {
        let heads = (0..<MonitorsConfig.maximumHeadCount).map { head(UInt32($0)) }
        #expect(try MonitorsConfig(decoding: encode(heads, maxAllowed: .max)).heads == heads)
        for count in [UInt16(MonitorsConfig.maximumHeadCount + 1), UInt16.max] {
            var writer = ByteWriter()
            writer.writeU16(count)
            writer.writeU16(.max)
            #expect(throws: WireError.limitExceeded("monitor heads")) {
                try MonitorsConfig(decoding: writer.bytes)
            }
        }
    }

    @Test func rejectsEveryTruncationAndTrailingData() {
        let bytes = encode([head(0), head(1)], maxAllowed: 4)
        for length in 0..<bytes.count {
            #expect(throws: WireError.self) { try MonitorsConfig(decoding: Array(bytes.prefix(length))) }
        }
        #expect(throws: WireError.invalidValue("monitor config trailing bytes")) {
            try MonitorsConfig(decoding: bytes + [0])
        }
    }

    @Test func rejectsAmbiguousIDsIncludingDisabledHeads() {
        #expect(throws: WireError.invalidValue("duplicate monitor id")) {
            try MonitorsConfig(decoding: encode([head(4), head(4)], maxAllowed: 4))
        }
        let disabled = MonitorHead(monitorID: 4, surfaceID: 9, width: 0, height: 0,
                                   x: 0, y: 0, flags: 0)
        #expect(throws: WireError.invalidValue("duplicate monitor id")) {
            try MonitorsConfig(decoding: encode([head(4), disabled], maxAllowed: 4))
        }
    }

    private func head(_ id: UInt32) -> MonitorHead {
        MonitorHead(monitorID: id, surfaceID: 0, width: 640, height: 480, x: id * 640, y: 0, flags: 0)
    }

    private func encode(_ heads: [MonitorHead], maxAllowed: UInt16) -> [UInt8] {
        var writer = ByteWriter()
        writer.writeU16(UInt16(heads.count))
        writer.writeU16(maxAllowed)
        for head in heads {
            for value in [head.monitorID, head.surfaceID, head.width, head.height, head.x, head.y, head.flags] {
                writer.writeU32(value)
            }
        }
        return writer.bytes
    }
}
