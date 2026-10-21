import SpiceWire

/// A smartcard on the Mac that can be shared with the guest (passthrough: the guest's
/// APDUs go to the real card unchanged).
public protocol SmartcardCard: Sendable {
    var displayName: String { get }
    /// Opens an exclusive session and returns the card's ATR.
    func connect() async throws -> [UInt8]
    /// Sends one command APDU and returns the response APDU (data + SW1 SW2).
    func transmit(_ apdu: [UInt8]) async throws -> [UInt8]
    /// Ends the session; the card goes back to macOS.
    func disconnect() async
}

public enum SmartcardError: Error, Equatable, Sendable {
    /// The server did not acknowledge the virtual reader (no smartcard device in the VM?).
    case readerNotAccepted
    case cardAlreadyShared
    case noATR
}

public enum SmartcardEvent: Sendable, Equatable {
    case inserted(name: String)
    case removed
}

/// The smartcard channel: one virtual reader in the guest (QEMU `ccid-card-passthru`)
/// backed by one card on the Mac at a time.
public actor SmartcardChannel {
    public static let capabilities = CapabilitySet(bits: [])
    static let readerName = "SpiceClient Smartcard Reader"

    private let connection: ChannelConnection
    private let events: AsyncStream<SmartcardEvent>.Continuation
    private let log = ChannelLogger(category: "smartcard")

    private var readerID: UInt32?
    private var readerWaiter: CheckedContinuation<UInt32?, Never>?
    private var card: (any SmartcardCard)?
    private var inserting = false
    private var closed = false

    public init(connection: ChannelConnection, events: AsyncStream<SmartcardEvent>.Continuation) {
        self.connection = connection
        self.events = events
    }

    public var sharedCardName: String? { card?.displayName }

    // MARK: Channel loop

    public func run() async throws {
        defer {
            closed = true
            readerWaiter?.resume(returning: nil)
            readerWaiter = nil
        }
        do {
            try await receiveLoop()
        } catch {
            // Channel gone (EOF, error): give the card back to macOS immediately.
            await releaseCard()
            await connection.close()
            throw error
        }
    }

    private func receiveLoop() async throws {
        while true {
            let message = try await connection.nextMessage()
            guard VSCMessage.isData(message) else { continue }
            let vsc: VSCMessage
            do {
                vsc = try VSCMessage(decoding: message.payload)
            } catch {
                log.error("malformed smartcard message: \(error)")
                continue
            }
            await handle(vsc)
        }
    }

    public func close() async {
        closed = true
        await releaseCard()
        await connection.close()
    }

    private func handle(_ message: VSCMessage) async {
        switch message.type {
        case .error:
            let code = message.errorCode ?? VSCErrorCode.generalError.rawValue
            if let waiter = readerWaiter {
                readerWaiter = nil
                waiter.resume(returning: code == VSCErrorCode.success.rawValue ? message.readerID : nil)
            } else if code != VSCErrorCode.success.rawValue {
                log.info("guest smartcard error \(code) for reader \(message.readerID)")
            }
        case .apdu:
            await transmit(message)
        case .flush:
            await send(VSCMessage(.flushComplete, readerID: message.readerID))
        case .initialize, .readerAdd, .readerRemove, .atr, .cardRemove, .flushComplete, nil:
            break
        }
    }

    private func transmit(_ message: VSCMessage) async {
        guard let card, message.readerID == readerID else {
            await send(.error(.generalError, readerID: message.readerID))
            return
        }
        do {
            let response = try await card.transmit(message.data)
            await send(VSCMessage(.apdu, readerID: message.readerID, data: response))
        } catch {
            log.info("APDU failed: \(error)")
            await send(.error(.generalError, readerID: message.readerID))
        }
    }

    // MARK: Insert / remove

    /// Inserts `newCard` into the guest's virtual reader.
    public func insert(_ newCard: any SmartcardCard) async throws {
        // `inserting` closes the window between the check and `card = newCard` (actor
        // reentrancy at the awaits below).
        guard !closed else { throw SmartcardError.readerNotAccepted }
        guard card == nil, !inserting else { throw SmartcardError.cardAlreadyShared }
        inserting = true
        defer { inserting = false }
        let reader = try await ensureReader()
        let atr = try await newCard.connect()
        guard !atr.isEmpty, !closed else {
            // Empty ATR, or the channel closed while the card was opening: don't leave an
            // exclusive session behind.
            await newCard.disconnect()
            throw closed ? SmartcardError.readerNotAccepted : SmartcardError.noATR
        }
        card = newCard
        await send(VSCMessage(.atr, readerID: reader, data: atr))
        events.yield(.inserted(name: newCard.displayName))
        log.info("card inserted into reader \(reader)")
    }

    /// Removes the card from the guest and gives it back to macOS.
    public func remove() async {
        guard card != nil else { return }
        if let readerID { await send(VSCMessage(.cardRemove, readerID: readerID)) }
        await releaseCard()
    }

    private func releaseCard() async {
        guard let current = card else { return }
        card = nil
        await current.disconnect()
        events.yield(.removed)
    }

    private func ensureReader() async throws -> UInt32 {
        if let readerID { return readerID }
        guard readerWaiter == nil else { throw SmartcardError.cardAlreadyShared }
        let add = VSCMessage(.readerAdd, readerID: VSCMessage.undefinedReaderID, data: Array(Self.readerName.utf8))
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            await self?.expireReaderWaiter()
        }
        // Install the waiter before sending so the acknowledgement can't arrive first.
        let assigned = await withCheckedContinuation { continuation in
            readerWaiter = continuation
            Task { await self.send(add) }
        }
        timeout.cancel()
        guard let assigned else { throw SmartcardError.readerNotAccepted }
        readerID = assigned
        return assigned
    }

    private func expireReaderWaiter() {
        readerWaiter?.resume(returning: nil)
        readerWaiter = nil
    }

    private func send(_ message: VSCMessage) async {
        do {
            try await connection.send(message.encode())
        } catch {
            log.debug("smartcard send failed: \(error)")
        }
    }
}
