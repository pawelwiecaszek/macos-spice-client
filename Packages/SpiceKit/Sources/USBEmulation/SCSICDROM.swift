/// Data returned by a SCSI command: fixed bytes or a range of image blocks.
struct SCSIResponse {
    enum Payload {
        case bytes([UInt8])
        case blocks(firstLBA: UInt64, count: Int)
    }

    var status: UInt8
    var payload: Payload
    var ejected = false

    var length: Int {
        switch payload {
        case .bytes(let bytes): bytes.count
        case .blocks(_, let count): count * SCSICDROM.blockSize
        }
    }

    func bytes(at offset: Int, count: Int, source: any BlockSource) throws -> [UInt8] {
        guard count > 0 else { return [] }
        switch payload {
        case .bytes(let bytes):
            return Array(bytes[offset..<min(bytes.count, offset + count)])
        case .blocks(let lba, _):
            let start = lba * UInt64(SCSICDROM.blockSize) + UInt64(offset)
            let data = try source.read(offset: start, count: count)
            guard data.count == count else { throw SCSIReadError.shortRead }
            return data
        }
    }
}

enum SCSIReadError: Error { case shortRead }

/// SCSI sense data (key / ASC / ASCQ).
struct Sense: Equatable {
    var key: UInt8
    var asc: UInt8
    var ascq: UInt8

    static let none = Sense(key: 0, asc: 0, ascq: 0)
    static let invalidCommand = Sense(key: 0x05, asc: 0x20, ascq: 0x00)
    static let invalidField = Sense(key: 0x05, asc: 0x24, ascq: 0x00)
    static let lbaOutOfRange = Sense(key: 0x05, asc: 0x21, ascq: 0x00)
    static let mediumNotPresent = Sense(key: 0x02, asc: 0x3A, ascq: 0x00)
    static let mediumChanged = Sense(key: 0x06, asc: 0x28, ascq: 0x00)
    static let writeProtected = Sense(key: 0x07, asc: 0x27, ascq: 0x00)
    static let unrecoveredReadError = Sense(key: 0x03, asc: 0x11, ascq: 0x00)
}

/// SCSI Multimedia Commands (MMC) subset for a read-only CD/DVD-ROM.
struct SCSICDROM {
    static let blockSize = 2048
    static let good: UInt8 = 0
    static let checkCondition: UInt8 = 1  // CSW "command failed"

    let blockCount: UInt64
    private(set) var sense = Sense.none
    private(set) var mediumPresent = true
    /// GET EVENT STATUS reports "new media" once after insertion.
    private var newMediaPending = true
    /// The first TEST UNIT READY reports UNIT ATTENTION (medium changed), like a real drive.
    private var unitAttentionPending = true

    init(blockCount: UInt64) {
        self.blockCount = blockCount
    }

    /// DVD profile for images larger than a CD.
    var isDVD: Bool { blockCount > 400_000 }

    mutating func fail(sense: Sense) -> SCSIResponse {
        self.sense = sense
        return SCSIResponse(status: Self.checkCondition, payload: .bytes([]))
    }

    private func ok(_ bytes: [UInt8] = [], allocation: Int? = nil) -> SCSIResponse {
        let limited = allocation.map { Array(bytes.prefix($0)) } ?? bytes
        return SCSIResponse(status: Self.good, payload: .bytes(limited))
    }

    mutating func execute(_ cdb: [UInt8], source: any BlockSource) -> SCSIResponse {
        guard let opcode = cdb.first else { return fail(sense: .invalidCommand) }
        func byte(_ index: Int) -> Int { index < cdb.count ? Int(cdb[index]) : 0 }
        func be16(_ index: Int) -> Int { byte(index) << 8 | byte(index + 1) }
        func be32(_ index: Int) -> UInt64 { UInt64(be16(index)) << 16 | UInt64(be16(index + 2)) }

        if opcode != 0x03 { sense = .none }  // REQUEST SENSE reports the previous command's sense
        let needsMedium: Set<UInt8> = [0x25, 0x28, 0xA8, 0x43, 0x51, 0x52]
        if needsMedium.contains(opcode) && !mediumPresent { return fail(sense: .mediumNotPresent) }

        switch opcode {
        case 0x00:  // TEST UNIT READY
            if !mediumPresent { return fail(sense: .mediumNotPresent) }
            if unitAttentionPending {
                unitAttentionPending = false
                return fail(sense: .mediumChanged)
            }
            return ok()

        case 0x03:  // REQUEST SENSE (fixed format)
            var data = [UInt8](repeating: 0, count: 18)
            data[0] = 0x70
            data[2] = sense.key
            data[7] = 10
            data[12] = sense.asc
            data[13] = sense.ascq
            sense = .none
            return ok(data, allocation: byte(4))

        case 0x12:  // INQUIRY
            return inquiry(evpd: byte(1) & 1 != 0, page: byte(2), allocation: be16(3))

        case 0x1A, 0x5A:  // MODE SENSE (6) / (10)
            return modeSense(ten: opcode == 0x5A, page: byte(2) & 0x3F,
                             allocation: opcode == 0x5A ? be16(7) : byte(4))

        case 0x1B:  // START STOP UNIT
            let loadEject = byte(4) & 0x02 != 0
            let start = byte(4) & 0x01 != 0
            if loadEject && !start {
                mediumPresent = false
                var response = ok()
                response.ejected = true
                return response
            }
            return ok()

        case 0x1E, 0x35, 0xBB, 0x2B:  // PREVENT/ALLOW, SYNCHRONIZE CACHE, SET CD SPEED, SEEK
            return ok()

        case 0x25:  // READ CAPACITY (10)
            let last = blockCount > 0 ? blockCount - 1 : 0
            return ok(be32Bytes(last) + be32Bytes(UInt64(Self.blockSize)))

        case 0x28, 0xA8:  // READ (10) / READ (12)
            let lba = be32(2)
            let count = opcode == 0x28 ? UInt64(be16(7)) : be32(6)
            guard lba + count <= blockCount, count <= 65_535 else { return fail(sense: .lbaOutOfRange) }
            return SCSIResponse(status: Self.good, payload: .blocks(firstLBA: lba, count: Int(count)))

        case 0x43:  // READ TOC/PMA/ATIP
            return readTOC(msf: byte(1) & 0x02 != 0, format: byte(2) & 0x0F, allocation: be16(7))

        case 0x46:  // GET CONFIGURATION
            return getConfiguration(allocation: be16(7))

        case 0x4A:  // GET EVENT STATUS NOTIFICATION
            guard byte(1) & 0x01 != 0 else { return fail(sense: .invalidField) }  // only polled mode
            return eventStatus(classes: byte(4), allocation: be16(7))

        case 0x51:  // READ DISC INFORMATION
            var data = [UInt8](repeating: 0, count: 34)
            data[0...1] = [0x00, 0x20]
            data[2] = 0x0E  // complete disc, last session complete
            data[3] = 1  // first track
            data[4] = 1  // sessions (LSB)
            data[5] = 1  // first track in last session
            data[6] = 1  // last track in last session
            data[7] = 0x20  // unrestricted use
            return ok(data, allocation: be16(7))

        case 0x52:  // READ TRACK INFORMATION
            var data = [UInt8](repeating: 0, count: 36)
            data[0...1] = [0x00, 0x22]
            data[2] = 1  // track
            data[3] = 1  // session
            data[5] = 0x04  // data track, uninterrupted
            data[6] = 0x01  // data mode 1
            data[24...27] = ArraySlice(be32Bytes(blockCount))  // track size
            return ok(data, allocation: be16(7))

        case 0xBD:  // MECHANISM STATUS
            return ok([0, 0, 0, 0, 0, 0, 0, 0], allocation: be16(8))

        default:
            return fail(sense: .invalidCommand)
        }
    }

    private mutating func inquiry(evpd: Bool, page: Int, allocation: Int) -> SCSIResponse {
        if evpd {
            switch page {
            case 0x00: return ok([0x05, 0x00, 0x00, 0x03, 0x00, 0x80, 0x83], allocation: allocation)
            case 0x80:
                let serial = Array("5350494345303031".utf8)
                return ok([0x05, 0x80, 0x00, UInt8(serial.count)] + serial, allocation: allocation)
            case 0x83:
                // One vendor-specific ASCII designator.
                let id = Array("SPICE   Virtual CD-ROM".utf8)
                return ok([0x05, 0x83, 0x00, UInt8(4 + id.count), 0x02, 0x00, 0x00, UInt8(id.count)] + id, allocation: allocation)
            default:
                return fail(sense: .invalidField)
            }
        }
        var data = [UInt8](repeating: 0x20, count: 36)
        data[0] = 0x05  // CD/DVD device
        data[1] = 0x80  // removable
        data[2] = 0x05  // SPC-3
        data[3] = 0x02  // response data format
        data[4] = 31  // additional length
        data[5] = 0; data[6] = 0; data[7] = 0
        data.replaceSubrange(8..<16, with: Array("SPICE   ".utf8))
        data.replaceSubrange(16..<32, with: Array("Virtual CD-ROM  ".utf8))
        data.replaceSubrange(32..<36, with: Array("1.0 ".utf8))
        return ok(data, allocation: allocation)
    }

    private mutating func modeSense(ten: Bool, page: Int, allocation: Int) -> SCSIResponse {
        // CD/DVD capabilities and mechanical status page (0x2A).
        let capabilities: [UInt8] = [
            0x2A, 0x14,
            0x3B, 0x00,  // reads CD-R/RW, DVD-ROM; writes nothing
            0x71, 0x63,  // audio play, mode 2 forms, multi-session…
            0x29, 0x00,  // tray, eject, lock supported
            0x02, 0xC2, 0x00, 0x02, 0x02, 0x00, 0x02, 0xC2,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        let errorRecovery: [UInt8] = [0x01, 0x06, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00]
        var pages: [UInt8]
        switch page {
        case 0x2A: pages = capabilities
        case 0x01: pages = errorRecovery
        case 0x3F: pages = errorRecovery + capabilities
        default:
            return fail(sense: .invalidField)
        }
        let medium: UInt8 = 0x00  // medium type: default/unspecified
        if ten {
            let total = 6 + pages.count
            pages = be16Bytes(total) + [medium, 0x00, 0, 0, 0, 0] + pages
        } else {
            pages = [UInt8(3 + pages.count), medium, 0x00, 0] + pages
        }
        return ok(pages, allocation: allocation)
    }

    private func address(_ lba: UInt64, msf: Bool) -> [UInt8] {
        guard msf else { return be32Bytes(lba) }
        let frames = lba + 150
        return [0, UInt8(frames / (75 * 60) & 0xFF), UInt8(frames / 75 % 60), UInt8(frames % 75)]
    }

    private mutating func readTOC(msf: Bool, format: Int, allocation: Int) -> SCSIResponse {
        switch format {
        case 0:  // formatted TOC: track 1 + lead-out
            var body: [UInt8] = [1, 1]
            body += [0, 0x14, 1, 0] + address(0, msf: msf)
            body += [0, 0x14, 0xAA, 0] + address(blockCount, msf: msf)
            return ok(be16Bytes(body.count) + body, allocation: allocation)
        case 1:  // multi-session info
            let body: [UInt8] = [1, 1, 0, 0x14, 1, 0] + address(0, msf: msf)
            return ok(be16Bytes(body.count) + body, allocation: allocation)
        default:
            return fail(sense: .invalidField)
        }
    }

    private func getConfiguration(allocation: Int) -> SCSIResponse {
        let current: UInt16 = isDVD ? 0x0010 : 0x0008
        // Profile list (feature 0x0000): DVD-ROM and CD-ROM.
        var features: [UInt8] = [0x00, 0x00, 0x03, 0x08,
                                 0x00, 0x10, isDVD ? 1 : 0, 0,
                                 0x00, 0x08, isDVD ? 0 : 1, 0]
        // Core (0x0001): physical interface USB (0x00000008).
        features += [0x00, 0x01, 0x0B, 0x08, 0x00, 0x00, 0x00, 0x08, 0x01, 0x00, 0x00, 0x00]
        // Removable medium (0x0003): tray, eject, lock.
        features += [0x00, 0x03, 0x03, 0x04, 0x29, 0x00, 0x00, 0x00]
        let header = be32Bytes(UInt64(4 + features.count)) + [0, 0, UInt8(current >> 8), UInt8(current & 0xFF)]
        return ok(header + features, allocation: allocation)
    }

    private mutating func eventStatus(classes: Int, allocation: Int) -> SCSIResponse {
        guard classes & 0x10 != 0 else {
            // No supported class requested: "no event available" header.
            return ok([0x00, 0x02, 0x80, 0x10], allocation: allocation)
        }
        let event: UInt8 = newMediaPending && mediumPresent ? 2 : 0
        newMediaPending = false
        let status: UInt8 = mediumPresent ? 0x02 : 0x00
        return ok([0x00, 0x06, 0x04, 0x10, event, status, 0, 0], allocation: allocation)
    }
}
