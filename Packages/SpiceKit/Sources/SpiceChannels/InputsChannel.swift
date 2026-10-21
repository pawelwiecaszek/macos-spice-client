import SpiceWire

/// User input to forward to the guest.
public enum InputEvent: Sendable, Equatable {
    /// PC XT set-1 scancode; extended (`0xE0`-prefixed) keys are `0x100 | code`.
    case keyDown(UInt16)
    case keyUp(UInt16)
    /// Host Caps Lock state, synced to the guest on focus gain (other locks are kept).
    case capsLock(Bool)
    /// Server mouse mode: relative motion.
    case motion(dx: Int32, dy: Int32, buttons: MouseButtonMask)
    /// Client mouse mode: absolute position in guest pixels.
    case position(x: UInt32, y: UInt32, buttons: MouseButtonMask, display: UInt8)
    case press(MouseButton, buttons: MouseButtonMask)
    case release(MouseButton, buttons: MouseButtonMask)
}

/// Inputs channel: keyboard, mouse and lock-state sync with motion-ack throttling.
public actor InputsChannel {
    public static let capabilities = CapabilitySet(bits: [InputsCapability.keyScancode.rawValue])

    private let connection: ChannelConnection
    private let log = ChannelLogger(category: "inputs")

    /// Unacknowledged motion/position messages (see `SPICE_INPUT_MOTION_ACK_BUNCH`).
    private var motionCount = 0
    private var pendingMotion: (dx: Int32, dy: Int32, buttons: MouseButtonMask)?
    private var pendingPosition: (x: UInt32, y: UInt32, buttons: MouseButtonMask, display: UInt8)?
    public private(set) var guestModifiers: KeyboardModifiers = []

    public init(connection: ChannelConnection) {
        self.connection = connection
    }

    /// Processes server messages (modifiers, motion acks) until closed.
    public func run() async throws {
        while true {
            let message = try await connection.nextMessage()
            switch InputsServerMessage(rawValue: message.type) {
            case .initialize, .keyModifiers:
                guestModifiers = try InputsModifiers(decoding: message.payload).modifiers
            case .mouseMotionAck:
                motionCount = max(0, motionCount - spiceInputMotionAckBunch)
                try await flushPendingMotion()
            case nil:
                log.debug("ignoring inputs message \(message.type)")
            }
        }
    }

    public func close() async {
        await connection.close()
    }

    public func send(_ event: InputEvent) async throws {
        switch event {
        case .keyDown(let code):
            try await connection.send(InputsClientEncoder.keyDown(scancode: code))
        case .keyUp(let code):
            try await connection.send(InputsClientEncoder.keyUp(scancode: code))
        case .capsLock(let on):
            var desired = guestModifiers
            if on { desired.insert(.capsLock) } else { desired.remove(.capsLock) }
            guard desired != guestModifiers else { return }
            try await connection.send(InputsClientEncoder.keyModifiers(desired))
        case .motion(let dx, let dy, let buttons):
            if let pending = pendingMotion {
                pendingMotion = (pending.dx &+ dx, pending.dy &+ dy, buttons)
            } else {
                pendingMotion = (dx, dy, buttons)
            }
            if motionCount < 2 * spiceInputMotionAckBunch { try await flushPendingMotion() }
        case .position(let x, let y, let buttons, let display):
            pendingPosition = (x, y, buttons, display)
            if motionCount < 2 * spiceInputMotionAckBunch { try await flushPendingMotion() }
        case .press(let button, let buttons):
            try await flushPendingMotion()
            try await connection.send(InputsClientEncoder.mousePress(button, buttons: buttons))
        case .release(let button, let buttons):
            try await flushPendingMotion()
            try await connection.send(InputsClientEncoder.mouseRelease(button, buttons: buttons))
        }
    }

    private func flushPendingMotion() async throws {
        if let motion = pendingMotion {
            pendingMotion = nil
            motionCount += 1
            try await connection.send(InputsClientEncoder.mouseMotion(dx: motion.dx, dy: motion.dy, buttons: motion.buttons))
        }
        if let position = pendingPosition {
            pendingPosition = nil
            motionCount += 1
            try await connection.send(InputsClientEncoder.mousePosition(
                x: position.x, y: position.y, buttons: position.buttons, displayID: position.display))
        }
    }
}
