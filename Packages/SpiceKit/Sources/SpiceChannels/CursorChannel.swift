import SpiceCodecs
import SpiceWire

/// A decoded cursor shape (premultiplied BGRA).
public struct CursorImage: Sendable, Equatable {
    public var image: PixelBuffer
    public var hotSpotX: Int
    public var hotSpotY: Int
}

/// Cursor updates for the UI.
public enum CursorEvent: Sendable, Equatable {
    /// New shape (`nil` = no cursor / invisible shape).
    case shape(CursorImage?)
    /// Guest-side cursor position (server mouse mode only).
    case move(x: Int, y: Int)
    case visible(Bool)
    case reset
}

/// Cursor channel: shapes, cache and position.
public actor CursorChannel {
    public static let capabilities = CapabilitySet()

    private let connection: ChannelConnection
    private let events: AsyncStream<CursorEvent>.Continuation
    private let log = ChannelLogger(category: "cursor")
    private var cache: [UInt64: CursorImage] = [:]
    static let maxCacheEntries = 256
    static let maxCursorSize: UInt16 = 512

    public init(connection: ChannelConnection, events: AsyncStream<CursorEvent>.Continuation) {
        self.connection = connection
        self.events = events
    }

    public func run() async throws {
        defer { events.finish() }
        while true {
            let message = try await connection.nextMessage()
            do {
                try handle(message)
            } catch {
                log.error("malformed cursor message \(message.type): \(error)")
            }
        }
    }

    public func close() async {
        await connection.close()
    }

    private func handle(_ message: SpiceMessage) throws {
        switch CursorServerMessage(rawValue: message.type) {
        case .initialize:
            let initMessage = try CursorInit(decoding: message.payload)
            events.yield(.shape(decode(initMessage.cursor)))
            events.yield(.move(x: Int(initMessage.position.x), y: Int(initMessage.position.y)))
            events.yield(.visible(initMessage.visible))
        case .set:
            let set = try CursorSet(decoding: message.payload)
            events.yield(.shape(decode(set.cursor)))
            events.yield(.move(x: Int(set.position.x), y: Int(set.position.y)))
            events.yield(.visible(set.visible))
        case .move:
            let move = try CursorMove(decoding: message.payload)
            events.yield(.move(x: Int(move.position.x), y: Int(move.position.y)))
        case .hide:
            events.yield(.visible(false))
        case .reset:
            cache.removeAll()
            events.yield(.reset)
        case .invalOne:
            cache.removeValue(forKey: try InvalidateOne(decoding: message.payload).id)
        case .invalAll:
            cache.removeAll()
        case .trail, nil:
            break
        }
    }

    private func decode(_ shape: CursorShape) -> CursorImage? {
        guard let header = shape.header else { return nil }  // SPICE_CURSOR_FLAGS_NONE
        if shape.flags.contains(.fromCache) { return cache[header.unique] }
        guard header.width > 0, header.height > 0,
              header.width <= Self.maxCursorSize, header.height <= Self.maxCursorSize else { return nil }
        let image = CursorDecoder.decode(header: header, data: shape.data)
        if let image, shape.flags.contains(.cacheMe) {
            if cache.count >= Self.maxCacheEntries { cache.removeAll() }
            cache[header.unique] = image
        }
        return image
    }
}

/// Converts SPICE cursor bitmaps to premultiplied BGRA.
public enum CursorDecoder {
    public static func decode(header: CursorHeader, data: ArraySlice<UInt8>) -> CursorImage? {
        let width = Int(header.width), height = Int(header.height)
        let maskStride = (width + 7) / 8
        var pixels = [UInt32](repeating: 0, count: width * height)
        let base = data.startIndex

        func maskBit(_ offset: Int, x: Int, y: Int) -> Bool {
            let index = offset + y * maskStride + x / 8
            guard index < data.endIndex else { return false }
            return data[index] & (0x80 >> UInt8(x & 7)) != 0
        }

        switch header.type {
        case .alpha:
            guard data.count >= width * height * 4 else { return nil }
            for i in 0..<(width * height) {
                let p = base + i * 4
                let b = UInt32(data[p]), g = UInt32(data[p + 1]), r = UInt32(data[p + 2]), a = UInt32(data[p + 3])
                // SPICE alpha cursors are straight (non-premultiplied) ARGB.
                pixels[i] = a << 24 | (r * a / 255) << 16 | (g * a / 255) << 8 | (b * a / 255)
            }
        case .mono:
            // AND mask followed by XOR mask, both 1 bpp.
            guard data.count >= 2 * maskStride * height else { return nil }
            let xorOffset = base + maskStride * height
            for y in 0..<height {
                for x in 0..<width {
                    let andBit = maskBit(base, x: x, y: y)
                    let xorBit = maskBit(xorOffset, x: x, y: y)
                    let value: UInt32
                    switch (andBit, xorBit) {
                    case (false, false): value = 0xFF00_0000  // black
                    case (false, true): value = 0xFFFF_FFFF  // white
                    case (true, false): value = 0  // transparent
                    case (true, true): value = 0xFF00_0000  // "invert" approximated as black
                    }
                    pixels[y * width + x] = value
                }
            }
        case .color32, .color24:
            let bytesPerPixel = header.type == .color32 ? 4 : 3
            let colorStride = width * bytesPerPixel
            guard data.count >= colorStride * height + maskStride * height else { return nil }
            let maskOffset = base + colorStride * height
            for y in 0..<height {
                for x in 0..<width {
                    let p = base + y * colorStride + x * bytesPerPixel
                    let transparent = maskBit(maskOffset, x: x, y: y)
                    let color = 0xFF00_0000 | UInt32(data[p + 2]) << 16 | UInt32(data[p + 1]) << 8 | UInt32(data[p])
                    pixels[y * width + x] = transparent ? 0 : color
                }
            }
        case .color4, .color8, .color16, nil:
            return nil
        }
        return CursorImage(image: PixelBuffer(width: width, height: height, pixels: pixels, hasAlpha: true),
                           hotSpotX: Int(header.hotSpotX), hotSpotY: Int(header.hotSpotY))
    }
}
