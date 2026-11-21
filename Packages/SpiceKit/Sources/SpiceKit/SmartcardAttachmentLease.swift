import Foundation
import SpiceChannels

/// One card insertion, independent of a replacement card or session.
public struct SmartcardAttachmentLease: Sendable {
    public let id: UUID
    private let channel: SmartcardChannel

    init(id: UUID, channel: SmartcardChannel) {
        self.id = id
        self.channel = channel
    }

    public func remove() async {
        await channel.remove(attachmentID: id)
    }
}
