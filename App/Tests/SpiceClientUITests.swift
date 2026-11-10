import XCTest

/// UI smoke tests. Session tests need a SPICE server and are not run here.
final class SpiceClientUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SPICE_RAVADA_TEST_SUITE"] =
            "com.pawelwiecaszek.spiceclient.uitests.\(UUID().uuidString)"
        return app
    }

    @MainActor
    func testLaunchShowsWelcomeWindow() throws {
        let app = makeApp()
        app.launch()
        XCTAssertTrue(app.buttons["Open Connection File…"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Proxmox Virtual Machines…"].exists)
        XCTAssertTrue(app.buttons["Open Ravada Portal…"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows["connectionsWindow"].screenshot())
        screenshot.name = "Launcher with Proxmox and Ravada"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testRavadaSetupOpensItsSettingsPane() throws {
        let app = makeApp()
        // Do not navigate to a real saved portal or modify its stored address.
        app.launchArguments = ["-ravadaPortalURL", ""]
        app.launch()
        let portal = app.buttons["Open Ravada Portal…"]
        XCTAssertTrue(portal.waitForExistence(timeout: 10))
        portal.click()
        let setup = app.buttons["manageRavadaPortals"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        setup.click()
        XCTAssertTrue(app.textFields["ravadaPortalURLField"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)
        let screenshot = XCTAttachment(screenshot: app.windows["connectionsWindow"].screenshot())
        screenshot.name = "Ravada portal settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testPortalFailureOffersRecoveryAndDiagnostics() throws {
        let app = makeApp()
        // Reserved .invalid domain: exercise network recovery without contacting a
        // saved portal, submitting credentials, or issuing machine actions.
        app.launchArguments = ["-ravadaPortalURL", "https://portal.example.invalid/"]
        app.launch()
        let portal = app.buttons["Open Ravada Portal…"]
        XCTAssertTrue(portal.waitForExistence(timeout: 10))
        portal.click()
        // SwiftUI presents this as a native macOS sheet; identify its controls
        // rather than depending on XCTest's alert/sheet element classification.
        let dismiss = app.buttons["Dismiss"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 40))
        XCTAssertTrue(app.staticTexts["Portal Action Failed"].exists)
        dismiss.click()
        XCTAssertTrue(app.buttons["stopPortalAction"].exists)
        let diagnostics = app.descendants(matching: .any)["portalDiagnosticsMenu"].firstMatch
        XCTAssertTrue(diagnostics.exists)
        diagnostics.click()
        let checkAccess = app.menuItems["Check Desktop Access"]
        XCTAssertTrue(checkAccess.waitForExistence(timeout: 5))
        checkAccess.click()
        XCTAssertTrue(app.staticTexts["ravadaCatalogCheckSummary"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)
        let screenshot = XCTAttachment(screenshot: app.windows["connectionsWindow"].screenshot())
        screenshot.name = "Portal recovery controls"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testSavedFavoritePortalSurvivesRelaunch() throws {
        let app = makeApp()
        app.launch()
        let portal = app.buttons["Open Ravada Portal…"]
        XCTAssertTrue(portal.waitForExistence(timeout: 10))
        portal.click()
        let setup = app.buttons["manageRavadaPortals"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        setup.click()
        let name = app.textFields["ravadaPortalNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.click()
        name.typeText("Test Portal")
        let address = app.textFields["ravadaPortalURLField"]
        address.click()
        address.typeText("https://portal.example.invalid/")
        let favorite = app.descendants(matching: .any)["ravadaPortalFavorite"].firstMatch
        XCTAssertTrue(favorite.exists)
        favorite.click()
        let save = app.buttons["saveRavadaPortal"]
        for _ in 0..<6 {
            if save.isHittable { break }
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -350)
        }
        XCTAssertTrue(save.isHittable)
        save.click()
        XCTAssertTrue(app.buttons["removeRavadaPortal"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows["connectionsWindow"].screenshot())
        screenshot.name = "Saved Ravada portal preferences"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        // Reuse this test's private suite; no production profiles are read or modified.
        app.launch()
        let favorites = app.descendants(matching: .any)["ravadaFavoritePortals"].firstMatch
        XCTAssertTrue(favorites.waitForExistence(timeout: 10))
        favorites.click()
        XCTAssertTrue(app.menuItems["Test Portal"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }
    @MainActor
    func testMainNavigationAndSettingsReuseOneWindowWithoutLosingDraftOnFocus() throws {
        let app = makeApp()
        app.launch()
        XCTAssertTrue(app.buttons["Open Connection File…"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(app.buttons["returnToPortal"].exists)
        app.buttons["showPortalProfiles"].click()
        let name = app.textFields["ravadaPortalNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.click()
        name.typeText("Unsaved draft")
        app.menuBarItems["File"].click()
        app.menuItems["Connections"].click()
        XCTAssertEqual(name.value as? String, "Unsaved draft")
        XCTAssertEqual(app.windows.count, 1)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["General"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["returnToPortal"].isHittable)
        XCTAssertEqual(app.windows.count, 1)
        app.buttons["showConnectionsHome"].click()
        XCTAssertTrue(app.buttons["Open Connection File…"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)
        let screenshot = XCTAttachment(screenshot: app.windows["connectionsWindow"].screenshot())
        screenshot.name = "One main connections window"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testNativeDesktopsSearchFavoritesAndPortalFallbackShareOneWindow() throws {
        let app = makeApp()
        app.launchEnvironment["SPICE_RAVADA_DESKTOP_FIXTURE"] = "1"
        app.launchArguments = ["-ravadaPortalURL", "https://portal.example.invalid/"]
        app.launch()
        app.buttons["openRavadaDesktops"].click()
        XCTAssertTrue(app.staticTexts["Example Running"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Example Stopped"].exists)
        XCTAssertTrue(app.staticTexts["Template Requiring Portal"].exists)
        XCTAssertFalse(app.buttons["connectRavadaDesktop-20"].exists)
        XCTAssertEqual(app.windows.count, 1)
        let screenshot = XCTAttachment(screenshot: app.windows["connectionsWindow"].screenshot())
        screenshot.name = "Native My Desktops"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let search = app.textFields["ravadaDesktopSearch"]
        search.click(); search.typeText("Running")
        XCTAssertTrue(app.staticTexts["Example Running"].exists)
        XCTAssertFalse(app.staticTexts["Example Stopped"].exists)
        app.buttons["ravadaDesktopFavorite-42"].click()
        search.click(); search.typeKey("a", modifierFlags: .command); search.typeKey(.delete, modifierFlags: [])
        app.descendants(matching: .any)["ravadaDesktopFavoritesOnly"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Example Running"].exists)
        XCTAssertFalse(app.staticTexts["Example Stopped"].exists)
        app.buttons["showConnectionsHome"].click()
        XCTAssertTrue(app.buttons["Open Connection File…"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)
    }

    @MainActor
    func testExpiredDesktopLoginShowsAccessGuidanceInsteadOfEmptyAccount() throws {
        let app = makeApp()
        app.launchEnvironment["SPICE_RAVADA_DESKTOP_FIXTURE"] = "expired"
        app.launchArguments = ["-ravadaPortalURL", "https://portal.example.invalid/"]
        app.launch()
        app.buttons["openRavadaDesktops"].click()
        XCTAssertTrue(app.staticTexts["Example Running"].waitForExistence(timeout: 10))
        app.buttons["refreshRavadaDesktops"].click()
        XCTAssertTrue(app.staticTexts["Desktop Access Unavailable"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["No Desktops Available"].exists)
        XCTAssertFalse(app.staticTexts["Ravada has not listed any desktops for this account."].exists)
        XCTAssertFalse(app.staticTexts["Example Running"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows["connectionsWindow"].screenshot())
        screenshot.name = "Desktop access guidance after sign out"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

}
