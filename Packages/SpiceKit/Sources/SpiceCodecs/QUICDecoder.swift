import SpiceWire

/// Decoder for `SPICE_IMAGE_TYPE_QUIC` images. See `QUICModel.swift` for an overview.
///
/// Stream: little-endian 32-bit words read MSB-first as a bit stream. Header words:
/// magic "QUIC" (0x43495551), version 0, type, width, height. Rows are top-down.
public enum QUICDecoder {
    /// `QuicImageType`.
    public enum ImageKind: UInt32, Sendable {
        case gray = 1, rgb16, rgb24, rgb32, rgba
    }

    static let magic: UInt32 = 0x4349_5551
    static let version: UInt32 = 0

    public static func decode(_ data: ArraySlice<UInt8>) throws(CodecError) -> PixelBuffer {
        let words = data.count / 4
        guard words > 0 else { throw .truncated }
        let wordBuffer = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: words)
        defer { wordBuffer.deallocate() }
        var p = data.startIndex
        for i in 0..<words {
            wordBuffer[i] = UInt32(data[p]) | UInt32(data[p + 1]) << 8 | UInt32(data[p + 2]) << 16 | UInt32(data[p + 3]) << 24
            p += 4
        }
        var bits = BitReader(words: UnsafeBufferPointer(wordBuffer))
        guard bits.word == magic else { throw .badMagic }
        try bits.eat32()
        let version = bits.word
        guard version == Self.version else { throw .unsupportedVersion(version) }
        try bits.eat32()
        let rawType = bits.word
        try bits.eat32()
        let width = Int(bits.word)
        try bits.eat32()
        let height = Int(bits.word)
        try bits.eat32()
        guard let kind = ImageKind(rawValue: rawType) else { throw .unsupportedType("quic type \(rawType)") }
        try CodecLimits.check(width: width, height: height)
        // The decoder only lives inside this call, so the word buffer outlives it.
        let decoder = Decoder(kind: kind, width: width, bits: bits)
        return try decoder.run(height: height)
    }

    // MARK: - Bit reader

    struct BitReader {
        private let words: UnsafeBufferPointer<UInt32>
        private var nextIndex = 1
        /// The current 32-bit window; the next codeword starts at its MSB.
        private(set) var word: UInt32
        private var nextWord: UInt32
        private var availableBits = 0
        /// Words requested past the end (the encoder pads with zeros when flushing).
        private var overrun = 0

        init(words: UnsafeBufferPointer<UInt32>) {
            self.words = words
            word = words[0]
            nextWord = words[0]
        }

        /// Consumes `count` bits (1...31).
        @inline(__always)
        mutating func eat(_ count: Int) throws(CodecError) {
            guard count > 0, count < 32 else { throw .corrupt("quic codeword length \(count)") }
            word <<= UInt32(count)
            let delta = availableBits - count
            if delta >= 0 {
                availableBits = delta
                word |= nextWord >> UInt32(availableBits)
                return
            }
            let missing = -delta
            word |= nextWord << UInt32(missing)
            if nextIndex < words.count {
                nextWord = words[nextIndex]
                nextIndex += 1
            } else {
                overrun += 1
                guard overrun <= 2 else { throw .truncated }
                nextWord = 0
            }
            availableBits = 32 - missing
            word |= nextWord >> UInt32(availableBits)
        }

        mutating func eat32() throws(CodecError) {
            try eat(16)
            try eat(16)
        }
    }

    // MARK: - Decoder

    /// Decoding state in flat, manually managed buffers (hot loop; avoids nested arrays).
    final class Decoder {
        let kind: ImageKind
        let width: Int
        var bits: BitReader
        let channelCount: Int
        let colorChannels: Int
        let bpc: Int
        let valueMask: UInt32
        var colorState = QUICCommonState()
        var alphaState = QUICCommonState()

        // Family tables.
        let unfold: UnsafeMutablePointer<UInt8>
        let codeLength: UnsafeMutablePointer<UInt32>
        let golombCodewords: [UInt32]
        let escapeLength: [Int]
        let escapeMask: [UInt32]
        let escapeSuffixMask: [UInt32]

        // Model: context → bucket map (same for every channel), counters and best codes.
        let bucketForContext: UnsafeMutablePointer<Int32>
        let bucketCount: Int
        let counters: UnsafeMutablePointer<UInt32>
        let bestCode: UnsafeMutablePointer<UInt8>

        /// `residuals[c * (width + 1) + k]`, k = 0 is the "-1" slot.
        let residuals: UnsafeMutablePointer<UInt8>
        var current: UnsafeMutablePointer<UInt8>
        var previous: UnsafeMutablePointer<UInt8>

        init(kind: ImageKind, width: Int, bits: BitReader) {
            self.kind = kind
            self.width = width
            self.bits = bits
            colorChannels = kind == .gray ? 1 : 3
            channelCount = kind == .rgba ? 4 : colorChannels
            bpc = kind == .rgb16 ? 5 : 8
            valueMask = lowBitsMask(bpc)
            let family = bpc == 5 ? QUICFamily.fiveBit : QUICFamily.eightBit
            golombCodewords = family.golombCodewords
            escapeLength = family.escapeCodewordLength
            escapeMask = family.escapePrefixMask
            escapeSuffixMask = family.escapeSuffixLength.map { lowBitsMask($0) }

            unfold = .allocate(capacity: 256)
            for i in 0..<256 { unfold[i] = UInt8(truncatingIfNeeded: family.unfold[i]) }
            codeLength = .allocate(capacity: family.codeLength.count)
            for i in family.codeLength.indices { codeLength[i] = family.codeLength[i] }

            let model = QUICBuckets(bitsPerChannel: bpc)
            bucketCount = model.bucketCount
            bucketForContext = .allocate(capacity: 256)
            for i in 0..<256 { bucketForContext[i] = Int32(model.bucketForContext[i & Int(valueMask)]) }
            counters = .allocate(capacity: channelCount * bucketCount * quicMaxCodes)
            counters.initialize(repeating: 0, count: channelCount * bucketCount * quicMaxCodes)
            bestCode = .allocate(capacity: channelCount * bucketCount)
            bestCode.initialize(repeating: UInt8(bpc - 1), count: channelCount * bucketCount)

            residuals = .allocate(capacity: channelCount * (width + 1))
            residuals.initialize(repeating: 0, count: channelCount * (width + 1))
            current = .allocate(capacity: channelCount * width)
            current.initialize(repeating: 0, count: channelCount * width)
            previous = .allocate(capacity: channelCount * width)
            previous.initialize(repeating: 0, count: channelCount * width)
        }

        deinit {
            unfold.deallocate()
            codeLength.deallocate()
            bucketForContext.deallocate()
            counters.deallocate()
            bestCode.deallocate()
            residuals.deallocate()
            current.deallocate()
            previous.deallocate()
        }

        func run(height: Int) throws(CodecError) -> PixelBuffer {
            var output = PixelBuffer(width: width, height: height, hasAlpha: kind == .rgba)
            for row in 0..<height {
                // residual[-1] starts at 0 on the first row, then carries residual[0] of the row above.
                for c in 0..<channelCount {
                    let base = c * (width + 1)
                    residuals[base] = row == 0 ? 0 : residuals[base + 1]
                }
                try decodeRow(first: row == 0, channels: 0..<colorChannels, state: &colorState)
                if kind == .rgba {
                    try decodeRow(first: row == 0, channels: 3..<4, state: &alphaState)
                }
                store(row: row, into: &output)
                swap(&current, &previous)
            }
            return output
        }

        private func store(row: Int, into output: inout PixelBuffer) {
            let w = width
            let r = current, g = current + w, b = current + 2 * w
            output.pixels.withUnsafeMutableBufferPointer { out in
                let base = row * w
                switch kind {
                case .rgb24, .rgb32:
                    for x in 0..<w { out[base + x] = opaque(r: UInt32(r[x]), g: UInt32(g[x]), b: UInt32(b[x])) }
                case .rgba:
                    let a = current + 3 * w
                    for x in 0..<w {
                        out[base + x] = UInt32(a[x]) << 24 | UInt32(r[x]) << 16 | UInt32(g[x]) << 8 | UInt32(b[x])
                    }
                case .rgb16:
                    for x in 0..<w {
                        out[base + x] = opaque(r: expand5(UInt32(r[x])), g: expand5(UInt32(g[x])), b: expand5(UInt32(b[x])))
                    }
                case .gray:
                    for x in 0..<w { out[base + x] = opaque(r: UInt32(r[x]), g: UInt32(r[x]), b: UInt32(r[x])) }
                }
            }
        }

        // MARK: Golomb + model

        @inline(__always)
        private func decodeResidual(channel c: Int, context: UInt8) throws(CodecError) -> UInt8 {
            let bucket = Int(bucketForContext[Int(context)])
            let l = Int(bestCode[c * bucketCount + bucket])
            let window = bits.word
            let value: UInt32
            let length: Int
            if window > escapeMask[l] {
                let zeros = window.leadingZeroBitCount
                length = zeros + 1 + l
                guard length < 32 else { throw .corrupt("quic codeword too long") }
                value = UInt32(zeros << l) | ((window >> UInt32(32 - length)) & lowBitsMask(l))
            } else {
                length = escapeLength[l]
                guard length > 0, length < 32 else { throw .corrupt("quic escape length") }
                value = golombCodewords[l] &+ ((window >> UInt32(32 - length)) & escapeSuffixMask[l])
            }
            try bits.eat(length)
            return UInt8(truncatingIfNeeded: value)
        }

        /// Adapts bucket statistics with the residual just coded at `index` (1-based).
        @inline(__always)
        private func updateModel(channels: Range<Int>, index: Int, trigger: UInt32) {
            for c in channels {
                let row = residuals + c * (width + 1)
                let bucket = Int(bucketForContext[Int(row[index - 1])])
                let value = Int(row[index])
                let counts = counters + (c * bucketCount + bucket) * quicMaxCodes
                let lengths = codeLength + value * quicMaxCodes
                var best = bpc - 1
                counts[best] &+= lengths[best]
                var bestLength = counts[best]
                var l = bpc - 2
                while l >= 0 {
                    counts[l] &+= lengths[l]
                    if counts[l] < bestLength {
                        best = l
                        bestLength = counts[l]
                    }
                    l -= 1
                }
                bestCode[c * bucketCount + bucket] = UInt8(best)
                if bestLength > trigger {
                    for k in 0..<bpc { counts[k] >>= 1 }
                }
            }
        }

        // MARK: Rows

        /// Splits a row into segments wherever the wait-mask index advances.
        private func decodeRow(first: Bool, channels: Range<Int>, state: inout QUICCommonState) throws(CodecError) {
            var position = 0
            var remaining = width
            while state.waitMaskIndex < quicWaitMaskMax, state.waitMaskLeft <= remaining {
                if state.waitMaskLeft > 0 {
                    try segment(first: first, channels: channels, state: &state, start: position,
                                end: position + state.waitMaskLeft)
                    position += state.waitMaskLeft
                    remaining -= state.waitMaskLeft
                }
                state.waitMaskIndex += 1
                state.updateTrigger()
                state.waitMaskLeft = quicWaitMaskStep
            }
            if remaining > 0 {
                try segment(first: first, channels: channels, state: &state, start: position, end: position + remaining)
                if state.waitMaskIndex < quicWaitMaskMax { state.waitMaskLeft -= remaining }
            }
        }

        /// Decodes pixel `i`: first row predicts from the left; later rows from left/above.
        @inline(__always)
        private func decodePixel(_ i: Int, first: Bool, channels: Range<Int>) throws(CodecError) {
            for c in channels {
                let res = residuals + c * (width + 1)
                let cur = current + c * width
                let residual = try decodeResidual(channel: c, context: res[i])
                res[i + 1] = residual
                let unfolded = UInt32(unfold[Int(residual)])
                let prediction: UInt32
                if first {
                    prediction = i == 0 ? 0 : UInt32(cur[i - 1])
                } else if i == 0 {
                    prediction = UInt32(previous[c * width])
                } else {
                    prediction = (UInt32(cur[i - 1]) + UInt32(previous[c * width + i])) >> 1
                }
                cur[i] = UInt8((unfolded &+ prediction) & valueMask)
            }
        }

        @inline(__always)
        private func samePixel(_ a: UnsafeMutablePointer<UInt8>, _ ia: Int, _ b: UnsafeMutablePointer<UInt8>, _ ib: Int,
                               channels: Range<Int>) -> Bool {
            for c in channels where a[c * width + ia] != b[c * width + ib] { return false }
            return true
        }

        /// Run prediction: the row above repeats at `i` and the current row repeated twice.
        @inline(__always)
        private func shouldStartRun(at i: Int, runIndex: Int, channels: Range<Int>) -> Bool {
            samePixel(previous, i - 1, previous, i, channels: channels)
                && runIndex != i && i > 2
                && samePixel(current, i - 1, current, i - 2, channels: channels)
        }

        private func segment(first: Bool, channels: Range<Int>, state: inout QUICCommonState,
                             start: Int, end: Int) throws(CodecError) {
            let waitMask = lowBitsMask(state.waitMaskIndex)
            var i = start
            var stop: Int
            var runIndex = 0
            if i == 0 {
                try decodePixel(0, first: first, channels: channels)
                if state.waitCount > 0 {
                    state.waitCount -= 1
                } else {
                    state.waitCount = Int(state.nextRandom() & waitMask)
                    updateModel(channels: channels, index: 1, trigger: state.trigger)
                }
                i += 1
                stop = i + state.waitCount
            } else {
                stop = i + state.waitCount
            }
            let allowRuns = !first  // the first row has no row above to predict runs from

            while true {
                var runRequested = false
                scan: while stop < end {
                    while i <= stop {
                        if allowRuns, shouldStartRun(at: i, runIndex: runIndex, channels: channels) {
                            runRequested = true
                            break scan
                        }
                        try decodePixel(i, first: first, channels: channels)
                        i += 1
                    }
                    updateModel(channels: channels, index: stop + 1, trigger: state.trigger)
                    stop = i + Int(state.nextRandom() & waitMask)
                }
                if !runRequested {
                    while i < end {
                        if allowRuns, shouldStartRun(at: i, runIndex: runIndex, channels: channels) {
                            runRequested = true
                            break
                        }
                        try decodePixel(i, first: first, channels: channels)
                        i += 1
                    }
                }
                if !runRequested {
                    state.waitCount = stop - end
                    return
                }

                // Run: repeat the left pixel. Residual history is intentionally not updated.
                state.waitCount = stop - i
                runIndex = i
                let length = try decodeRunLength(state: &state)
                guard length >= 0, length <= end - i else { throw .corrupt("quic run length") }
                let runEnd = i + length
                while i < runEnd {
                    for c in channels { current[c * width + i] = current[c * width + i - 1] }
                    i += 1
                }
                if i == end { return }
                stop = i + state.waitCount
            }
        }

        /// MELCODE adaptive run length.
        private func decodeRunLength(state: inout QUICCommonState) throws(CodecError) -> Int {
            var length = 0
            while true {
                let topByte = UInt8(truncatingIfNeeded: ~(bits.word >> 24))
                let ones = topByte.leadingZeroBitCount  // leading ones of the window (8 if all)
                for _ in 0..<ones {
                    length += state.melcOrder
                    if state.melcState < quicMelcodeOrders.count - 1 {
                        state.melcState += 1
                        state.melcLength = quicMelcodeOrders[state.melcState]
                        state.melcOrder = 1 << state.melcLength
                    }
                }
                if ones != 8 {
                    try bits.eat(ones + 1)  // the ones plus the terminating zero
                    break
                }
                try bits.eat(8)
            }
            if state.melcLength > 0 {
                length += Int(bits.word >> UInt32(32 - state.melcLength))
                try bits.eat(state.melcLength)
            }
            if state.melcState > 0 {
                state.melcState -= 1
                state.melcLength = quicMelcodeOrders[state.melcState]
                state.melcOrder = 1 << state.melcLength
            }
            return length
        }
    }
}
