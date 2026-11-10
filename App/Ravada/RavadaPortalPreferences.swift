/// Optional session overrides; nil inherits the General setting at launch time.
struct RavadaPortalPreferences: Codable, Equatable, Sendable {
    var resizeGuestWithWindow: Bool?
    var useRetinaResolution: Bool?
    var sendCommandKeyToGuest: Bool?
    var shareClipboard: Bool?
    var playGuestAudio: Bool?

    var isEmpty: Bool {
        resizeGuestWithWindow == nil && useRetinaResolution == nil
            && sendCommandKeyToGuest == nil && shareClipboard == nil && playGuestAudio == nil
    }
}
