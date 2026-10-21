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
    }
}
