import Foundation
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
    /// Identifies the card lifetime that ended; slot-independent cleanup uses this event.
    case attachmentRemoved(id: UUID)
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
    private var attachmentID: UUID?
    private var insertingID: UUID?
    private var insertionWaiters: [CheckedContinuation<Void, Never>] = []
    private var cleanupID: UUID?
    private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []
    private var removal: (id: UUID, task: Task<Void, Never>)?
    private var readerWaiterID: UUID?
    private var closed = false

    public init(connection: ChannelConnection, events: AsyncStream<SmartcardEvent>.Continuation) {
        self.connection = connection
        self.events = events
    }

    public var sharedCardName: String? { card?.displayName }

    // MARK: Channel loop

    public func run() async throws {
        do {
            try await receiveLoop()
        } catch {
            await failChannel()
            throw error
        }
    }

    private func receiveLoop() async throws {
        while true {
            await connection.messageHandled()
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
        await failChannel()
    }

    /// Close the wire before waiting on device cleanup, so blocked sends can finish.
    private func failChannel() async {
        closed = true
        expireReaderWaiter()
        await connection.close()
        await releaseCard()
    }

    private func handle(_ message: VSCMessage) async {
        switch message.type {
        case .error:
            let code = message.errorCode ?? VSCErrorCode.generalError.rawValue
            if let waiter = readerWaiter {
                readerWaiter = nil
                readerWaiterID = nil
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
        guard let card, let attachmentID, message.readerID == readerID else {
            await send(.error(.generalError, readerID: message.readerID))
            return
        }
        do {
            let response = try await card.transmit(message.data)
            guard self.attachmentID == attachmentID, !closed else { return }
            await send(VSCMessage(.apdu, readerID: message.readerID, data: response))
        } catch {
            guard self.attachmentID == attachmentID, !closed else { return }
            log.info("smartcard APDU failed")
            await send(.error(.generalError, readerID: message.readerID))
        }
    }

    // MARK: Insert / remove

    /// Inserts `newCard` into the guest's virtual reader.
    /// A supplied attachment ID must be fresh for each insertion.
    public func insert(_ newCard: any SmartcardCard, attachmentID: UUID = UUID()) async throws {
        try Task.checkCancellation()
        guard !closed else { throw SmartcardError.readerNotAccepted }
        guard card == nil, insertingID == nil, cleanupID == nil else { throw SmartcardError.cardAlreadyShared }
        insertingID = attachmentID
        defer {
            insertingID = nil
            let waiters = insertionWaiters
            insertionWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        var connectAttempted = false
        var transferred = false
        do {
            let reader = try await ensureReader()
            try Task.checkCancellation()
            guard !closed else { throw SmartcardError.readerNotAccepted }
            connectAttempted = true
            let atr = try await newCard.connect()
            try Task.checkCancellation()
            guard !closed else { throw SmartcardError.readerNotAccepted }
            guard !atr.isEmpty else { throw SmartcardError.noATR }
            card = newCard
            self.attachmentID = attachmentID
            transferred = true
            do {
                try await connection.send(VSCMessage(.atr, readerID: reader, data: atr).encode())
            } catch {
                // A partial ATR write leaves peer state ambiguous; do not reuse the channel.
                await failChannel()
                throw error
            }
            guard !closed, self.attachmentID == attachmentID else { throw SmartcardError.readerNotAccepted }
            events.yield(.inserted(name: newCard.displayName))
            log.info("card inserted into reader \(reader)")
        } catch {
            if transferred {
                if self.attachmentID == attachmentID { await releaseCard() }
                await waitForCleanup(attachmentID)
            } else if connectAttempted {
                await newCard.disconnect()
            }
            throw error
        }
    }

    /// Removes the current card. Use its attachment ID for delayed cleanup.
    public func remove() async {
        guard let id = attachmentID ?? cleanupID ?? insertingID else { return }
        await remove(attachmentID: id)
    }

    /// Releases only one insertion, including any cleanup already underway.
    public func remove(attachmentID: UUID) async {
        if let removal, removal.id == attachmentID {
            await removal.task.value
            return
        }
        if cleanupID == attachmentID {
            await waitForCleanup(attachmentID)
            return
        }
        guard self.attachmentID == attachmentID || insertingID == attachmentID else { return }
        let task = Task { await self.performRemove(attachmentID) }
        removal = (attachmentID, task)
        await task.value
        if removal?.id == attachmentID { removal = nil }
    }

    private func performRemove(_ id: UUID) async {
        // A pending reader/connect cannot safely be replayed after cancellation.
        if insertingID == id, attachmentID != id {
            await failChannel()
            await waitForInsertion()
            return
        }
        if let readerID {
            do {
                try await connection.send(VSCMessage(.cardRemove, readerID: readerID).encode())
            } catch {
                await failChannel()
                return
            }
        }
        if attachmentID == id { await releaseCard() }
        await waitForCleanup(id)
    }

    private func releaseCard() async {
        guard let current = card, let id = attachmentID else {
            if let cleanupID { await waitForCleanup(cleanupID) }
            return
        }
        cleanupID = id
        card = nil
        attachmentID = nil
        await current.disconnect()
        events.yield(.removed)
        events.yield(.attachmentRemoved(id: id))
        cleanupID = nil
        let waiters = cleanupWaiters
        cleanupWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForCleanup(_ id: UUID) async {
        guard cleanupID == id else { return }
        await withCheckedContinuation { cleanupWaiters.append($0) }
    }

    private func waitForInsertion() async {
        guard insertingID != nil else { return }
        await withCheckedContinuation { insertionWaiters.append($0) }
    }

    private func ensureReader() async throws -> UInt32 {
        if let readerID { return readerID }
        guard !closed, readerWaiter == nil else { throw SmartcardError.readerNotAccepted }
        let id = UUID()
        let add = VSCMessage(.readerAdd, readerID: VSCMessage.undefinedReaderID, data: Array(Self.readerName.utf8))
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.expireReaderWaiter(ifID: id)
        }
        // The reader request has an independent writer so feature cancellation cannot
        // cancel the shared channel socket. Install the waiter before sending.
        let assigned = await withCheckedContinuation { continuation in
            readerWaiterID = id
            readerWaiter = continuation
            Task { await self.sendReaderAdd(add, id: id) }
        }
        timeout.cancel()
        guard !closed, let assigned, assigned != VSCMessage.undefinedReaderID else {
            // A late acknowledgement cannot be correlated with a replacement attempt.
            await failChannel()
            throw SmartcardError.readerNotAccepted
        }
        readerID = assigned
        return assigned
    }

    private func sendReaderAdd(_ message: VSCMessage, id: UUID) async {
        guard !closed, readerWaiterID == id else { return }
        do { try await connection.send(message.encode()) }
        catch { await failChannel() }
    }

    private func expireReaderWaiter(ifID: UUID? = nil) {
        if let ifID, readerWaiterID != ifID { return }
        readerWaiterID = nil
        readerWaiter?.resume(returning: nil)
        readerWaiter = nil
    }

    private func send(_ message: VSCMessage) async {
        do { try await connection.send(message.encode()) }
        catch { await failChannel() }
    }
}
