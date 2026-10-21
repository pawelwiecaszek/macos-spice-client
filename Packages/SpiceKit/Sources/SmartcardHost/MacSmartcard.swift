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
public actor MacSmartcard: SmartcardCard, CCIDCard {
    public nonisolated let displayName: String
    private var card: TKSmartCard?

    public init(readerName: String) {
        displayName = readerName
    }

    public func connect() async throws -> [UInt8] {
        guard let manager = TKSmartCardSlotManager.default else { throw MacSmartcardError.noAccess }
        guard let slot = manager.slotNamed(displayName) else { throw MacSmartcardError.readerGone }
        guard slot.state == .validCard, let atr = slot.atr?.bytes, let card = slot.makeSmartCard() else {
            throw MacSmartcardError.noCard
        }
        let reason: String? = await withCheckedContinuation { continuation in
            card.beginSession { ok, error in
                continuation.resume(returning: ok ? nil : (error?.localizedDescription ?? "unknown error"))
            }
        }
        if let reason { throw MacSmartcardError.sessionRefused(reason) }
        self.card = card
        return [UInt8](atr)
    }

    public func transmit(_ apdu: [UInt8]) async throws -> [UInt8] {
        guard let card, card.isValid else { throw MacSmartcardError.noCard }
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

    public func disconnect() async {
        card?.endSession()
        card = nil
    }

    /// `false` once the card was pulled or the reader unplugged.
    public var isPresent: Bool { card?.isValid ?? false }
}
#endif
