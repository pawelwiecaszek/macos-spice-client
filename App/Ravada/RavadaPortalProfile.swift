import Foundation

/// Saved portal metadata. WebKit owns authentication data under the opaque store ID.
struct RavadaPortalProfile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var address: String
    var isFavorite = false
    var websiteDataStoreID = UUID()
    var preferences = RavadaPortalPreferences()

    var url: URL? { RavadaPortalConfiguration.portalURL(address) }
}
