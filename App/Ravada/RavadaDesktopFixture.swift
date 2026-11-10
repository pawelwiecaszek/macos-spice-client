#if DEBUG
import Foundation
import SpiceKit

/// Synthetic UI-test data is enabled only inside an explicitly isolated test suite.
/// It never contacts a server or opens a connection.
@MainActor
enum RavadaDesktopFixture {
    static func store(profile: RavadaPortalProfile, defaults: UserDefaults) -> RavadaDesktopStore? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SPICE_RAVADA_DESKTOP_FIXTURE"] == "1",
              environment["SPICE_RAVADA_TEST_SUITE"]?.hasPrefix("com.pawelwiecaszek.spiceclient.uitests.") == true else { return nil }
        let body = #"[{"id":10,"name":"Example Linux","is_base":1,"list_clones":[{"id":42,"name":"Example Running","is_active":1,"is_locked":0},{"id":43,"name":"Example Stopped","is_active":0,"is_locked":0}]},{"id":20,"name":"Template Requiring Portal","is_base":1,"list_clones":[]}]"#
        return RavadaDesktopStore(profile: profile, defaults: defaults,
            request: { request in
                guard request == .catalog else { throw RavadaBrokerError.portalRequired }
                return .init(data: Data(body.utf8), status: 200, contentType: "application/json")
            }, cancel: {}, open: { _, _ in false })
    }
}
#endif
