#if canImport(CryptoTokenKit)
import CryptoTokenKit
import Foundation
import SpiceChannels
import USBEmulation

/// A smartcard reader slot on the Mac (built-in CCID driver; YubiKeys appear here too).
public struct SmartcardReaderInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var hasCard: Bool
    public var id: String { name }

    public init(name: String, hasCard: Bool) {
        self.name = name
        self.hasCard = hasCard
    }
}

public enum MacSmartcardError: Error, Equatable, Sendable, LocalizedError {
    /// No `com.apple.security.smartcard` entitlement, or the smartcard service is off.
    case noAccess
    case readerGone
    case noCard
    case sessionRefused(String)
    case transmitFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAccess: "This Mac doesn't allow the app to use smartcards."
        case .readerGone: "The smartcard reader is no longer connected."
        case .noCard: "There is no usable card in the reader."
        case .sessionRefused(let reason): "macOS didn't hand over the card (\(reason)). Close apps using it and try again."
        case .transmitFailed(let reason): "The card stopped responding (\(reason))."
        }
    }
}

/// Lists smartcard readers through CryptoTokenKit.
public enum SmartcardHost {
    /// `false` when the app lacks the smartcard entitlement.
    public static var isAvailable: Bool { TKSmartCardSlotManager.default != nil }

    /// Current readers, sorted by name.
    public static func readers() -> [SmartcardReaderInfo] {
        guard let manager = TKSmartCardSlotManager.default else { return [] }
        return manager.slotNames.sorted().map { name in
            SmartcardReaderInfo(name: name, hasCard: manager.slotNamed(name)?.state == .validCard)
        }
    }
}

/// The card in one reader, used exclusively while shared with the guest.
///
/// One CryptoTokenKit session stays open for the whole time the card is shared, so the
/// guest's APDU sequences (select applet → verify PIN → sign) are never interleaved with
/// commands from macOS.
/// Internal seam keeps ownership tests independent of CryptoTokenKit hardware.
protocol MacSmartcardSession: Sendable {
    var atr: [UInt8] { get }
    var isValid: Bool { get }
    func begin() async throws
    func transmit(_ apdu: [UInt8]) async throws -> [UInt8]
    func end() async
}

private final class CryptoTokenSession: MacSmartcardSession, @unchecked Sendable {
    // CryptoTokenKit's callback-based card is used only by its owning MacSmartcard actor.
    private let card: TKSmartCard
    let atr: [UInt8]
    var isValid: Bool { card.isValid }

    init(card: TKSmartCard, atr: [UInt8]) {
        self.card = card
        self.atr = atr
    }

    func begin() async throws {
        let reason: String? = await withCheckedContinuation { continuation in
            card.beginSession { ok, error in
                continuation.resume(returning: ok ? nil : (error?.localizedDescription ?? "unknown error"))
            }
        }
        if let reason { throw MacSmartcardError.sessionRefused(reason) }
    }

    func transmit(_ apdu: [UInt8]) async throws -> [UInt8] {
        let result: Result<Data, MacSmartcardError> = await withCheckedContinuation { continuation in
            card.transmit(Data(apdu)) { reply, error in
                if let reply {
                    continuation.resume(returning: .success(reply))
                } else {
                    continuation.resume(returning: .failure(.transmitFailed(error?.localizedDescription ?? "no reply")))
                }
            }
        }
        return [UInt8](try result.get())
    }

    func end() async { card.endSession() }
}

public actor MacSmartcard: SmartcardCard, CCIDCard {
    public nonisolated let displayName: String
    private let makeSession: @Sendable (String) async throws -> any MacSmartcardSession
    private var card: (id: UUID, session: any MacSmartcardSession)?
    private var generation = UUID()
    private var connecting: UUID?
    private var transmitting: UUID?
    private var disconnectTask: Task<Void, Never>?

    public init(readerName: String) {
        displayName = readerName
        makeSession = { name in
            guard let manager = TKSmartCardSlotManager.default else { throw MacSmartcardError.noAccess }
            guard let slot = manager.slotNamed(name) else { throw MacSmartcardError.readerGone }
            guard slot.state == .validCard, let atr = slot.atr?.bytes, let card = slot.makeSmartCard() else {
                throw MacSmartcardError.noCard
            }
            return CryptoTokenSession(card: card, atr: [UInt8](atr))
        }
    }

    init(readerName: String, makeSession: @escaping @Sendable (String) async throws -> any MacSmartcardSession) {
        displayName = readerName
        self.makeSession = makeSession
    }

    public func connect() async throws -> [UInt8] {
        try Task.checkCancellation()
        guard card == nil, connecting == nil, transmitting == nil, disconnectTask == nil else {
            throw MacSmartcardError.sessionRefused("A card operation is already in progress.")
        }
        let id = UUID(), current = generation
        connecting = id
        defer { connecting = nil }
        let acquired = try await makeSession(displayName)
        guard current == generation, !Task.isCancelled else { throw CancellationError() }
        try await acquired.begin()
        guard current == generation, !Task.isCancelled else {
            // A disconnect during beginSession cannot cancel CryptoTokenKit's callback;
            // the callback retains ownership and releases any late successful acquisition.
            await acquired.end()
            throw CancellationError()
        }
        card = (id, acquired)
        return acquired.atr
    }

    public func transmit(_ apdu: [UInt8]) async throws -> [UInt8] {
        try Task.checkCancellation()
        guard let card, card.session.isValid, transmitting == nil, disconnectTask == nil else {
            throw MacSmartcardError.noCard
        }
        transmitting = card.id
        defer { transmitting = nil }
        let result = try await card.session.transmit(apdu)
        guard self.card?.id == card.id, !Task.isCancelled else { throw CancellationError() }
        return result
    }

    public func disconnect() async {
        generation = UUID()
        if let disconnectTask {
            await disconnectTask.value
            return
        }
        guard let current = card else { return }
        card = nil
        let task = Task { await current.session.end() }
        disconnectTask = task
        await task.value
        disconnectTask = nil
    }

    /// `false` once the card was pulled, revoked, or the reader unplugged.
    public var isPresent: Bool { card?.session.isValid ?? false }
}
#endif
