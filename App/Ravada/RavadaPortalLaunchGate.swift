/// Ravada can automatically offer a connection after a desktop becomes ready.
/// A manual View handoff satisfies that initial offer too; a later background
/// offer must not silently replace the already opened viewer.
struct RavadaPortalLaunchGate {
    private var initialOfferAvailable = false

    mutating func beganDocument() {
        initialOfferAvailable = true
    }

    mutating func invalidate() {
        initialOfferAvailable = false
    }

    mutating func accept(isUserInitiated: Bool) -> Bool {
        guard initialOfferAvailable || isUserInitiated else { return false }
        initialOfferAvailable = false
        return true
    }
}
