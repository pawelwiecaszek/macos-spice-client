import Foundation
import Testing
@testable import SpiceClient

@MainActor
struct RavadaPortalStoreTests {
    @Test func hostedAppSharedStoreDoesNotUseProductionPreferences() {
        #expect(RavadaPortalStore.shared.defaults !== UserDefaults.standard)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "com.pawelwiecaszek.spiceclient.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func legacyMigrationPreservesBrowserLoginAndRunsOnlyOnce() throws {
        try withDefaults { defaults in
            let browserID = UUID()
            defaults.set(" https://portal.example.invalid/ravada/ ", forKey: RavadaPortalConfiguration.urlKey)
            defaults.set(["portal.example.invalid:443": browserID.uuidString], forKey: "ravadaPortalWebsiteDataStores")
            let migrated = RavadaPortalStore(defaults: defaults)
            let profile = try #require(migrated.selectedProfile)
            #expect(profile.address == "https://portal.example.invalid/ravada/")
            #expect(profile.websiteDataStoreID == browserID)
            #expect(profile.preferences.isEmpty)
            #expect(migrated.profiles.count == 1)
            let reloaded = RavadaPortalStore(defaults: defaults)
            #expect(reloaded.selectedProfile == profile)
            #expect(reloaded.errorMessage == nil)
            #expect(reloaded.canModify)
        }
    }

    @Test func emptyFirstLaunchDoesNotPreventLaterLoginPreservingMigration() throws {
        try withDefaults { defaults in
            let first = RavadaPortalStore(defaults: defaults)
            #expect(first.profiles.isEmpty)
            #expect(defaults.object(forKey: RavadaPortalStore.profilesKey) == nil)
            let previousBrowserID = UUID()
            defaults.set("https://portal.example.invalid/", forKey: RavadaPortalConfiguration.urlKey)
            defaults.set(["portal.example.invalid:443": previousBrowserID.uuidString],
                         forKey: "ravadaPortalWebsiteDataStores")
            let migrated = RavadaPortalStore(defaults: defaults)
            let profile = try #require(migrated.selectedProfile)
            #expect(profile.websiteDataStoreID == previousBrowserID)
            #expect(migrated.profiles.count == 1)
        }
    }

    @Test func deletingTheLastProfileDoesNotReimportLegacySettings() throws {
        try withDefaults { defaults in
            defaults.set("https://portal.example.invalid/", forKey: RavadaPortalConfiguration.urlKey)
            let store = RavadaPortalStore(defaults: defaults)
            let original = try #require(store.selectedProfile)
            let removed = try store.remove(original.id)
            #expect(removed == original)
            #expect(store.selectedID == nil)
            #expect(store.profiles.isEmpty)
            #expect(defaults.data(forKey: RavadaPortalStore.profilesKey) != nil)
            let reloaded = RavadaPortalStore(defaults: defaults)
            #expect(reloaded.profiles.isEmpty)
            #expect(reloaded.selectedProfile == nil)
            #expect(defaults.string(forKey: RavadaPortalConfiguration.urlKey) != nil)
        }
    }

    @Test func newProfilesIsolateLoginsEvenWhenTheOriginMatches() throws {
        try withDefaults { defaults in
            let store = RavadaPortalStore(defaults: defaults)
            let first = try store.add(name: "Work", address: "https://portal.example.invalid/")
            let second = try store.add(name: "Other account", address: first.address)
            #expect(first.id != second.id)
            #expect(first.websiteDataStoreID != second.websiteDataStoreID)
            #expect(store.selectedID == first.id)
            try store.select(second.id)
            let oldStore = try store.rotateLogin(profileID: first.id)
            #expect(oldStore == first.websiteDataStoreID)
            #expect(store.profiles.first?.websiteDataStoreID != first.websiteDataStoreID)
            #expect(store.selectedProfile == second)
        }
    }

    @Test func editingOriginRotatesOnlyThatProfilesBrowserStore() throws {
        try withDefaults { defaults in
            let store = RavadaPortalStore(defaults: defaults)
            let first = try store.add(name: "Work", address: "https://portal.example.invalid/")
            let other = try store.add(name: "Other", address: "https://other.example.invalid/")
            var draft = first
            draft.name = "Renamed"
            draft.address = "https://PORTAL.example.invalid:443/new/path/"
            draft.websiteDataStoreID = other.websiteDataStoreID
            let renamed = try store.update(draft)
            #expect(renamed.id == first.id)
            #expect(renamed.websiteDataStoreID == first.websiteDataStoreID)
            draft = renamed
            draft.address = "https://portal.example.invalid:8443/"
            let changed = try store.update(draft)
            #expect(changed.websiteDataStoreID != first.websiteDataStoreID)
            #expect(changed.websiteDataStoreID != other.websiteDataStoreID)
            #expect(store.profiles.last == other)
        }
    }

    @Test func preferencesFavoritesAndSelectionSurviveReload() throws {
        try withDefaults { defaults in
            let store = RavadaPortalStore(defaults: defaults)
            let preferences = RavadaPortalPreferences(resizeGuestWithWindow: false, useRetinaResolution: true,
                sendCommandKeyToGuest: nil, shareClipboard: false, playGuestAudio: true)
            let zulu = try store.add(name: "Zulu", address: "https://zulu.example.invalid/",
                                     isFavorite: true, preferences: preferences)
            let alpha = try store.add(name: "Alpha", address: "https://alpha.example.invalid/")
            try store.setFavorite(alpha.id, isFavorite: true)
            try store.select(alpha.id)
            let reloaded = RavadaPortalStore(defaults: defaults)
            #expect(reloaded.favorites.map(\.id) == [alpha.id, zulu.id])
            #expect(reloaded.profiles.first?.preferences == preferences)
            #expect(reloaded.selectedID == alpha.id)
            _ = try reloaded.remove(alpha.id)
            #expect(reloaded.selectedID == zulu.id)
            #expect(reloaded.profiles.first == zulu)
            #expect(RavadaPortalStore(defaults: defaults).selectedID == zulu.id)
        }
    }

    @Test func rejectsSecretBearingAddressesAndInvalidNamesWithoutSaving() throws {
        try withDefaults { defaults in
            let store = RavadaPortalStore(defaults: defaults)
            let original = defaults.data(forKey: RavadaPortalStore.profilesKey)
            for address in ["http://portal.example.invalid/", "https://user:secret@portal.example.invalid/",
                            "https://portal.example.invalid/?ticket=must-not-persist",
                            "https://portal.example.invalid/#token", "file:///tmp/config.vv",
                            "https://portal.example.invalid:0/", String(repeating: "a", count: 4097)] {
                #expect(throws: RavadaPortalStore.StoreError.self) {
                    try store.add(name: "Test", address: address)
                }
            }
            for name in ["", "   ", String(repeating: "x", count: 81), "line\nbreak"] {
                #expect(throws: RavadaPortalStore.StoreError.self) {
                    try store.add(name: name, address: "https://portal.example.invalid/")
                }
            }
            #expect(store.profiles.isEmpty)
            #expect(defaults.data(forKey: RavadaPortalStore.profilesKey) == original)
        }
    }

    @Test func profileLimitAndUnknownSelectionCannotMutateSavedMetadata() throws {
        try withDefaults { defaults in
            let store = RavadaPortalStore(defaults: defaults)
            for index in 0..<RavadaPortalStore.maxProfiles {
                _ = try store.add(name: "Portal \(index)", address: "https://portal\(index).example.invalid/")
            }
            let original = defaults.data(forKey: RavadaPortalStore.profilesKey)
            #expect(throws: RavadaPortalStore.StoreError.self) {
                try store.add(name: "Too many", address: "https://extra.example.invalid/")
            }
            #expect(throws: RavadaPortalStore.StoreError.self) { try store.select(UUID()) }
            #expect(store.profiles.count == 32)
            #expect(defaults.data(forKey: RavadaPortalStore.profilesKey) == original)
        }
    }

    @Test func corruptedMetadataIsPreservedAndAllWritesAreBlocked() throws {
        try withDefaults { defaults in
            let corrupt = Data("not-json-secret-marker".utf8)
            defaults.set(corrupt, forKey: RavadaPortalStore.profilesKey)
            defaults.set("https://legacy.example.invalid/", forKey: RavadaPortalConfiguration.urlKey)
            let store = RavadaPortalStore(defaults: defaults)
            #expect(!store.canModify)
            #expect(store.errorMessage != nil)
            #expect(!(store.errorMessage ?? "").contains("secret-marker"))
            #expect(throws: RavadaPortalStore.StoreError.self) {
                try store.add(name: "New", address: "https://new.example.invalid/")
            }
            #expect(throws: RavadaPortalStore.StoreError.self) { try store.select(nil) }
            #expect(throws: RavadaPortalStore.StoreError.self) { try store.remove(UUID()) }
            #expect(throws: RavadaPortalStore.StoreError.self) { try store.rotateLogin(profileID: UUID()) }
            #expect(defaults.data(forKey: RavadaPortalStore.profilesKey) == corrupt)
        }
    }

    @Test func decodedDuplicateIdentityOrBrowserStoreIsRejectedWithoutOverwrite() throws {
        for sharedID in [true, false] {
            try withDefaults { defaults in
                let first = RavadaPortalProfile(name: "First", address: "https://first.example.invalid/")
                var second = RavadaPortalProfile(name: "Second", address: "https://second.example.invalid/")
                if sharedID { second.id = first.id }
                else { second.websiteDataStoreID = first.websiteDataStoreID }
                let data = try JSONEncoder().encode([first, second])
                defaults.set(data, forKey: RavadaPortalStore.profilesKey)
                let store = RavadaPortalStore(defaults: defaults)
                #expect(!store.canModify)
                #expect(store.profiles.isEmpty)
                #expect(defaults.data(forKey: RavadaPortalStore.profilesKey) == data)
            }
        }
    }

    @Test func invalidLegacyValueIsRetainedUntilAnExplicitValidSave() throws {
        try withDefaults { defaults in
            let legacy = "https://portal.example.invalid/?token=must-not-copy"
            defaults.set(legacy, forKey: RavadaPortalConfiguration.urlKey)
            let store = RavadaPortalStore(defaults: defaults)
            #expect(store.canModify)
            #expect(store.profiles.isEmpty)
            #expect(store.errorMessage != nil)
            #expect(defaults.string(forKey: RavadaPortalConfiguration.urlKey) == legacy)
            #expect(defaults.object(forKey: RavadaPortalStore.profilesKey) == nil)
            _ = try store.add(name: "Saved", address: "https://safe.example.invalid/")
            #expect(store.errorMessage == nil)
            #expect(RavadaPortalStore(defaults: defaults).profiles.count == 1)
        }
    }

    @Test func migrationTruncatesOnlyTheGeneratedNameForLongValidHosts() throws {
        try withDefaults { defaults in
            let host = String(repeating: "a", count: 50) + "." + String(repeating: "b", count: 50) + ".example.invalid"
            let address = "https://\(host)/"
            let browserID = UUID()
            defaults.set(address, forKey: RavadaPortalConfiguration.urlKey)
            defaults.set(["\(host):443": browserID.uuidString], forKey: "ravadaPortalWebsiteDataStores")
            let store = RavadaPortalStore(defaults: defaults)
            let profile = try #require(store.selectedProfile)
            #expect(profile.name.count == 80)
            #expect(profile.address == address)
            #expect(profile.websiteDataStoreID == browserID)
        }
    }

    @Test func invalidDecodedAddressesCountsAndStorageTypesRemainUntouched() throws {
        let invalid = RavadaPortalProfile(name: "Invalid", address: "http://portal.example.invalid/")
        let tooMany = (0...RavadaPortalStore.maxProfiles).map {
            RavadaPortalProfile(name: "Portal \($0)", address: "https://portal\($0).example.invalid/")
        }
        for profiles in [[invalid], tooMany] {
            try withDefaults { defaults in
                let data = try JSONEncoder().encode(profiles)
                defaults.set(data, forKey: RavadaPortalStore.profilesKey)
                let store = RavadaPortalStore(defaults: defaults)
                #expect(!store.canModify)
                #expect(defaults.data(forKey: RavadaPortalStore.profilesKey) == data)
            }
        }
        try withDefaults { defaults in
            defaults.set("unexpected storage type", forKey: RavadaPortalStore.profilesKey)
            let store = RavadaPortalStore(defaults: defaults)
            #expect(!store.canModify)
            #expect(defaults.string(forKey: RavadaPortalStore.profilesKey) == "unexpected storage type")
        }
    }
}
