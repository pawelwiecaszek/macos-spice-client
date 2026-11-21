import Foundation
import SpiceChannels

/// Identity of a single USB attachment, independent of slot reuse or reconnect.
public struct USBAttachmentLease: Sendable {
    public let slot: Int
    public let id: UUID
    private let channel: USBRedirChannel

    init(slot: Int, id: UUID, channel: USBRedirChannel) {
        self.slot = slot
        self.id = id
        self.channel = channel
    }

    /// Releases only this attachment. Repeated or delayed calls are harmless.
    public func detach() async {
        await channel.detach(attachmentID: id)
    }
}
