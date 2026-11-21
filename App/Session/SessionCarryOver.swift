import Foundation

/// What the user had shared with the guest when the connection dropped.
struct SessionCarryOver: Equatable {
    var usbDevices: [UInt64] = []
    var isos: [URL] = []
    var smartcardReader: String?
    var microphone = false

    var isEmpty: Bool { usbDevices.isEmpty && isos.isEmpty && smartcardReader == nil && !microphone }
}
