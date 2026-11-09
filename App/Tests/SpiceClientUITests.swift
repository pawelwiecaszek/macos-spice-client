import XCTest

/// UI smoke tests. Session tests need a SPICE server and are not run here.
final class SpiceClientUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsWelcomeWindow() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Open Connection File…"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Proxmox Virtual Machines…"].exists)
        XCTAssertTrue(app.buttons["Open Ravada Portal…"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows["Welcome"].screenshot())
        screenshot.name = "Launcher with Proxmox and Ravada"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testRavadaSetupOpensItsSettingsPane() throws {
        let app = XCUIApplication()
        // Do not navigate to a real saved portal or modify its stored address.
        app.launchArguments = ["-ravadaPortalURL", ""]
        app.launch()
        let portal = app.buttons["Open Ravada Portal…"]
        XCTAssertTrue(portal.waitForExistence(timeout: 10))
        portal.click()
        let setup = app.buttons["Open Settings…"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        setup.click()
        XCTAssertTrue(app.textFields["ravadaPortalURLField"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.windows["Ravada"].screenshot())
        screenshot.name = "Ravada portal settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testPortalFailureOffersRecoveryAndDiagnostics() throws {
        let app = XCUIApplication()
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
        let screenshot = XCTAttachment(screenshot: app.windows["Ravada Portal"].screenshot())
        screenshot.name = "Portal recovery controls"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
