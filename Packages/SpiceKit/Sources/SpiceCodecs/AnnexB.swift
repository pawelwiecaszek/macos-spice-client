/// H.264 / H.265 Annex B byte streams, as produced by spice-server's GStreamer encoders
/// (`stream-format=byte-stream`): NAL units separated by 00 00 01 / 00 00 00 01 start codes.
public enum AnnexB {
    /// NAL unit payloads (without start codes), in order. Trailing zero bytes of a unit
    /// (part of a 4-byte start code or stuffing) are dropped.
    public static func nalUnits(_ data: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        var units: [ArraySlice<UInt8>] = []
        var index = data.startIndex
        let end = data.endIndex
        var unitStart: Int?
        while index + 2 < end {
            if data[index] == 0, data[index + 1] == 0, data[index + 2] == 1 {
                if let start = unitStart { units.append(trimmed(data[start..<index])) }
                index += 3
                unitStart = index
            } else {
                index += 1
            }
        }
        if let start = unitStart, start < end { units.append(trimmed(data[start..<end])) }
        return units.filter { !$0.isEmpty }
    }

    private static func trimmed(_ unit: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var unit = unit
        while unit.last == 0 { unit = unit.dropLast() }
        return unit
    }

    /// The NAL unit type (H.264: low 5 bits of byte 0; H.265: bits 1–6 of byte 0).
    public static func nalType(_ unit: ArraySlice<UInt8>, hevc: Bool) -> UInt8 {
        guard let first = unit.first else { return 0 }
        return hevc ? (first >> 1) & 0x3F : first & 0x1F
    }

    /// `true` for parameter-set NAL units (H.264 SPS/PPS; H.265 VPS/SPS/PPS).
    public static func isParameterSet(_ type: UInt8, hevc: Bool) -> Bool {
        hevc ? (32...34).contains(type) : type == 7 || type == 8
    }

    /// Converts NAL units to the length-prefixed (AVCC/HVCC, 4-byte) form decoders take.
    public static func lengthPrefixed(_ units: [ArraySlice<UInt8>]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            let n = UInt32(unit.count)
            out += [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            out += unit
        }
        return out
    }
}
