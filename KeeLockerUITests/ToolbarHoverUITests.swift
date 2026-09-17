import XCTest

@MainActor
final class ToolbarHoverUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testToolbarDoesNotExposeHoverProbeToAccessibility() {
        let app = XCUIApplication()
        app.launch()

        let sortButton = app.menuButtons["toolbar.sort"]
        let addButton = app.buttons["toolbar.add"]
        XCTAssertTrue(sortButton.waitForExistence(timeout: 3))
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        XCTAssertEqual(sortButton.value as? String, "")
        XCTAssertEqual(addButton.value as? String, "")
    }

    func testToolbarGeometryAndHoverStates() {
        let app = XCUIApplication()
        app.launchEnvironment["KEELOCKER_UI_TESTING"] = "1"
        app.launch()

        let sortButton = app.menuButtons["toolbar.sort"]
        let addButton = app.buttons["toolbar.add"]
        let actionGroup = app.groups["toolbar.actions"]
        XCTAssertTrue(sortButton.waitForExistence(timeout: 3))
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        XCTAssertTrue(actionGroup.waitForExistence(timeout: 3))
        XCTAssertEqual(actionGroup.frame.width, 80, accuracy: 0.5)
        XCTAssertEqual(actionGroup.frame.height, 40, accuracy: 0.5)

        addButton.hover()

        XCTAssertEqual(sortButton.value as? String, "idle")
        XCTAssertEqual(addButton.value as? String, "hovered")

        sortButton.hover()

        XCTAssertEqual(sortButton.value as? String, "hovered")
        XCTAssertEqual(addButton.value as? String, "idle")
    }
}
