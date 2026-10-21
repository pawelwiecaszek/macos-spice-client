import USBRedirWire

/// USB Mass Storage Class Bulk-Only Transport state machine (CBW → data → CSW).
struct BulkOnlyTransport {
    static let cbwSignature: UInt32 = 0x4342_5355  // "USBC"
    static let cswSignature: UInt32 = 0x5342_5355  // "USBS"

    enum Phase {
        case idle
        case dataIn(tag: UInt32, expected: Int, sent: Int, response: SCSIResponse)
        case dataOut(tag: UInt32, expected: Int, received: Int, status: UInt8)
        case status(tag: UInt32, residue: Int, status: UInt8)
        /// Invalid CBW: the device stalls until a Bulk-Only Reset.
        case halted
    }

    private(set) var phase: Phase = .idle

    mutating func clearHalt() {
        if case .halted = phase { return }  // only a BOMS reset recovers from an invalid CBW
    }

    mutating func handleOut(_ data: [UInt8], scsi: inout SCSICDROM, source: any BlockSource,
                            onEject: (@Sendable () -> Void)?) -> USBTransferResult {
        switch phase {
        case .idle:
            guard data.count == 31, le32(data, 0) == Self.cbwSignature else {
                phase = .halted
                return .failed(.stall)
            }
            let tag = le32(data, 4)
            let expected = Int(le32(data, 8))
            let directionIn = data[12] & 0x80 != 0
            let cdbLength = Int(data[14] & 0x1F)
            guard (1...16).contains(cdbLength) else {
                phase = .halted
                return .failed(.stall)
            }
            let cdb = Array(data[15..<(15 + cdbLength)])
            var response = scsi.execute(cdb, source: source)
            if response.ejected { onEject?() }
            if expected == 0 {
                phase = .status(tag: tag, residue: 0, status: response.status)
            } else if directionIn {
                phase = .dataIn(tag: tag, expected: expected, sent: 0, response: response)
            } else {
                // We are read-only: accept and discard OUT data, then report the result.
                if response.status == SCSICDROM.good { response = scsi.fail(sense: .writeProtected) }
                phase = .dataOut(tag: tag, expected: expected, received: 0, status: response.status)
            }
            return USBTransferResult(status: .success, actualLength: data.count)
        case .dataOut(let tag, let expected, let received, let status):
            let total = received + data.count
            phase = total >= expected
                ? .status(tag: tag, residue: max(0, expected - total), status: status)
                : .dataOut(tag: tag, expected: expected, received: total, status: status)
            return USBTransferResult(status: .success, actualLength: data.count)
        case .dataIn, .status, .halted:
            return .failed(.stall)
        }
    }

    mutating func handleIn(maxLength: Int, scsi: inout SCSICDROM, source: any BlockSource) -> USBTransferResult {
        switch phase {
        case .dataIn(let tag, let expected, let sent, let response):
            let available = min(expected, response.length) - sent
            let chunk = max(0, min(maxLength, available))
            let bytes: [UInt8]
            do {
                bytes = try response.bytes(at: sent, count: chunk, source: source)
            } catch {
                // Media read failure: end the data phase short and report MEDIUM ERROR.
                _ = scsi.fail(sense: .unrecoveredReadError)
                phase = .status(tag: tag, residue: expected - sent, status: SCSICDROM.checkCondition)
                return USBTransferResult(status: .success)
            }
            let newSent = sent + bytes.count
            let finished = newSent >= min(expected, response.length) || bytes.count < maxLength
            if finished {
                phase = .status(tag: tag, residue: expected - newSent, status: response.status)
            } else {
                phase = .dataIn(tag: tag, expected: expected, sent: newSent, response: response)
            }
            return USBTransferResult(status: .success, data: bytes)
        case .status(let tag, let residue, let status):
            phase = .idle
            var csw = [UInt8]()
            csw += le32Bytes(Self.cswSignature)
            csw += le32Bytes(tag)
            csw += le32Bytes(UInt32(clamping: max(0, residue)))
            csw.append(status)
            return USBTransferResult(status: .success, data: Array(csw.prefix(maxLength)))
        case .idle, .dataOut, .halted:
            return .failed(.stall)
        }
    }
}

@inline(__always)
func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
}

@inline(__always)
func le32Bytes(_ value: UInt32) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
}

@inline(__always)
func be16Bytes(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }

@inline(__always)
func be32Bytes(_ value: UInt64) -> [UInt8] {
    let v = UInt32(clamping: value)
    return [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
}
