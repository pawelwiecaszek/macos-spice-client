import Foundation
import Observation

/// Stores bounded profile metadata without copying cookies, credentials or .vv files.
@MainActor
@Observable
final class RavadaPortalStore {
    static let shared = RavadaPortalStore(defaults: sharedDefaults())
    static let profilesKey = "ravadaPortalProfiles"
    static let selectedKey = "ravadaSelectedPortalID"
    static let maxProfiles = 32
    private static let maxStoredBytes = 256 * 1024

    private(set) var profiles: [RavadaPortalProfile] = []
    private(set) var selectedID: UUID?
    private(set) var errorMessage: String?
    /// Injected preference domain; internal so hosted tests can verify isolation.
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var unreadableProfiles = false

    var canModify: Bool { !unreadableProfiles }
    var selectedProfile: RavadaPortalProfile? { profiles.first { $0.id == selectedID } }
    var favorites: [RavadaPortalProfile] {
        profiles.filter(\.isFavorite).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.profilesKey) != nil {
            do {
                guard let data = defaults.data(forKey: Self.profilesKey), data.count <= Self.maxStoredBytes else {
                    throw StoreError.unreadableData
                }
                let decoded = try JSONDecoder().decode([RavadaPortalProfile].self, from: data)
                profiles = try Self.validated(decoded)
                let saved = defaults.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:))
                selectedID = profiles.contains { $0.id == saved } ? saved : profiles.first?.id
            } catch {
                unreadableProfiles = true
                errorMessage = StoreError.unreadableData.localizedDescription
            }
        } else {
            migrateLegacyProfile()
        }
    }

    @discardableResult
    func add(name: String, address: String, isFavorite: Bool = false,
             preferences: RavadaPortalPreferences = .init()) throws -> RavadaPortalProfile {
        try ensureWritable()
        guard profiles.count < Self.maxProfiles else { throw StoreError.tooManyProfiles }
        let profile = try Self.validated(RavadaPortalProfile(name: name, address: address,
                                                           isFavorite: isFavorite, preferences: preferences))
        try persist(profiles + [profile], selectedID: selectedID ?? profile.id)
        return profile
    }

    @discardableResult
    func update(_ proposed: RavadaPortalProfile) throws -> RavadaPortalProfile {
        try ensureWritable()
        guard let index = profiles.firstIndex(where: { $0.id == proposed.id }) else { throw StoreError.profileNotFound }
        let existing = profiles[index]
        var profile = try Self.validated(proposed)
        // The caller may edit a draft but must not choose another profile's login store.
        profile.websiteDataStoreID = existing.websiteDataStoreID
        if let oldURL = existing.url, let newURL = profile.url,
           !RavadaPortalConfiguration.sameOrigin(newURL, as: oldURL) {
            profile.websiteDataStoreID = UUID()
        }
        var updated = profiles
        updated[index] = profile
        try persist(updated, selectedID: selectedID)
        return profile
    }

    func select(_ id: UUID?) throws {
        try ensureWritable()
        if let id, !profiles.contains(where: { $0.id == id }) { throw StoreError.profileNotFound }
        try persist(profiles, selectedID: id ?? profiles.first?.id)
    }

    func setFavorite(_ id: UUID, isFavorite: Bool) throws {
        try ensureWritable()
        guard var profile = profiles.first(where: { $0.id == id }) else { throw StoreError.profileNotFound }
        profile.isFavorite = isFavorite
        try update(profile)
    }

    @discardableResult
    func remove(_ id: UUID) throws -> RavadaPortalProfile? {
        try ensureWritable()
        guard let profile = profiles.first(where: { $0.id == id }) else { return nil }
        let remaining = profiles.filter { $0.id != id }
        try persist(remaining, selectedID: selectedID == id ? remaining.first?.id : selectedID)
        return profile
    }

    /// Returns the old store identifier so the UI can erase it after closing its browser.
    @discardableResult
    func rotateLogin(profileID: UUID) throws -> UUID? {
        try ensureWritable()
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return nil }
        var updated = profiles
        let previous = updated[index].websiteDataStoreID
        updated[index].websiteDataStoreID = UUID()
        try persist(updated, selectedID: selectedID)
        return previous
    }

    private func ensureWritable() throws {
        if unreadableProfiles { throw StoreError.unreadableData }
    }

    private func persist(_ updated: [RavadaPortalProfile], selectedID: UUID?) throws {
        try ensureWritable()
        let validated = try Self.validated(updated)
        guard let data = try? JSONEncoder().encode(validated), data.count <= Self.maxStoredBytes else {
            throw StoreError.cannotSave
        }
        defaults.set(data, forKey: Self.profilesKey)
        if let selectedID { defaults.set(selectedID.uuidString, forKey: Self.selectedKey) }
        else { defaults.removeObject(forKey: Self.selectedKey) }
        profiles = validated
        self.selectedID = selectedID
        errorMessage = nil
    }

    private func migrateLegacyProfile() {
        guard let legacy = defaults.string(forKey: RavadaPortalConfiguration.urlKey),
              !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Merely opening the app without an address is not a completed migration.
            // A later launch may supply the existing portal via arguments. Only an
            // explicit removal persists [], preventing deliberately removed profiles
            // from being resurrected without blocking that first real migration.
            return
        }
        do {
            let address = try Self.validatedAddress(legacy)
            guard let url = RavadaPortalConfiguration.portalURL(address) else { throw StoreError.invalidAddress }
            let name = String((url.host ?? String(localized: "Ravada Portal")).prefix(80))
            var profile = RavadaPortalProfile(name: name, address: address)
            let origin = "\(url.host?.lowercased() ?? ""):\(url.port ?? 443)"
            if let stores = defaults.dictionary(forKey: "ravadaPortalWebsiteDataStores") as? [String: String],
               let value = stores[origin], let id = UUID(uuidString: value) {
                profile.websiteDataStoreID = id
            }
            try persist([profile], selectedID: profile.id)
        } catch {
            // Keep the legacy value intact. A deliberate new save can replace it;
            // merely reading an invalid old setting must not silently erase it.
            errorMessage = String(localized: "The previous portal address could not be imported. Add a valid HTTPS portal address to continue.")
        }
    }

    private static func validated(_ profiles: [RavadaPortalProfile]) throws -> [RavadaPortalProfile] {
        guard profiles.count <= maxProfiles else { throw StoreError.tooManyProfiles }
        guard Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map(\.websiteDataStoreID)).count == profiles.count else { throw StoreError.unreadableData }
        return try profiles.map(validated)
    }

    private static func validated(_ profile: RavadaPortalProfile) throws -> RavadaPortalProfile {
        var normalized = profile
        normalized.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.name.isEmpty, normalized.name.count <= 80,
              !normalized.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw StoreError.invalidName
        }
        normalized.address = try validatedAddress(profile.address)
        return normalized
    }

    private static func validatedAddress(_ address: String) throws -> String {
        guard let url = RavadaPortalConfiguration.portalURL(address),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil else { throw StoreError.invalidAddress }
        return url.absoluteString
    }

    private static func sharedDefaults() -> UserDefaults {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["SPICE_RAVADA_TEST_SUITE"],
           suite.hasPrefix("com.pawelwiecaszek.spiceclient.uitests."),
           let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        // Hosted integration tests launch the app too, before the tests instantiate
        // their own stores. Keep that initial UI away from production preferences.
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestBundlePath"] != nil || environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil {
            if let defaults = UserDefaults(suiteName: "com.pawelwiecaszek.spiceclient.unittests.\(UUID().uuidString)") {
                return defaults
            }
        }
        #endif
        return .standard
    }

    enum StoreError: Error, LocalizedError {
        case invalidName, invalidAddress, profileNotFound, tooManyProfiles, unreadableData, cannotSave

        var errorDescription: String? {
            switch self {
            case .invalidName: String(localized: "Enter a portal name of 1–80 characters without control characters.")
            case .invalidAddress: String(localized: "Enter an HTTPS portal address without credentials, a query, or a fragment.")
            case .profileNotFound: String(localized: "This saved portal is no longer available.")
            case .tooManyProfiles: String(localized: "You can save up to 32 Ravada portals. Remove one before adding another.")
            case .unreadableData: String(localized: "Saved Ravada portals could not be read. They have been preserved, and changes are disabled to avoid overwriting them.")
            case .cannotSave: String(localized: "The saved Ravada portals could not be updated.")
            }
        }
    }
}
