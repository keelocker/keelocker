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
        let detailSplitter = app.splitters.element(boundBy: 1)
        let expectedTrailingInset: CGFloat = 8
        XCTAssertTrue(sortButton.waitForExistence(timeout: 3))
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        XCTAssertTrue(actionGroup.waitForExistence(timeout: 3))
        XCTAssertTrue(detailSplitter.waitForExistence(timeout: 3))
        XCTAssertEqual(actionGroup.frame.width, 80, accuracy: 0.5)
        XCTAssertEqual(actionGroup.frame.height, 40, accuracy: 0.5)
        XCTAssertEqual(
            actionGroup.frame.maxX,
            detailSplitter.frame.minX - expectedTrailingInset,
            accuracy: 0.5
        )

        addButton.hover()

        XCTAssertEqual(sortButton.value as? String, "idle")
        XCTAssertTrue(waitForValue("hovered", on: addButton))

        sortButton.hover()

        XCTAssertTrue(waitForValue("hovered", on: sortButton))
        XCTAssertTrue(waitForValue("idle", on: addButton))
    }

    func testToolbarSearchMatchesActionHeight() {
        let app = XCUIApplication()
        app.launch()

        let searchContainer = app.groups["toolbar.searchContainer"]
        let actionGroup = app.groups["toolbar.actions"]
        let detailSplitter = app.splitters.element(boundBy: 1)
        XCTAssertTrue(searchContainer.waitForExistence(timeout: 3))
        XCTAssertTrue(actionGroup.waitForExistence(timeout: 3))
        XCTAssertTrue(detailSplitter.waitForExistence(timeout: 3))
        XCTAssertEqual(searchContainer.frame.height, 40, accuracy: 0.5)
        XCTAssertEqual(searchContainer.frame.height, actionGroup.frame.height, accuracy: 0.5)
        XCTAssertGreaterThan(searchContainer.frame.minX, detailSplitter.frame.maxX)
    }

    func testToolbarSearchReleasesFocusAfterOutsideClick() {
        let app = XCUIApplication()
        app.launchEnvironment["KEELOCKER_UI_TESTING"] = "1"
        app.launch()

        let searchField = app.descendants(matching: .any)["toolbar.search"]
        let searchContainer = app.groups["toolbar.searchContainer"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        XCTAssertTrue(searchContainer.waitForExistence(timeout: 3))

        searchField.click()
        XCTAssertTrue(waitForFocusState("focused", on: searchField))

        searchContainer
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 2))
            .click()
        XCTAssertTrue(waitForFocusState("idle", on: searchField))
    }

    func testToolbarSearchKeepsFocusWhenFilteringHidesCurrentSelection() {
        let app = XCUIApplication()
        app.launchEnvironment["KEELOCKER_UI_TESTING"] = "1"
        app.launch()

        let searchField = app.descendants(matching: .any)["toolbar.search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))

        searchField.click()
        searchField.typeText("GitHub")

        let updatedSearchField = app.descendants(matching: .any)["toolbar.search"]
        XCTAssertTrue(waitForValue("focused|GitHub", on: updatedSearchField))
        XCTAssertTrue(app.staticTexts["1 login"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Select a login"].waitForExistence(timeout: 2))
    }

    func testToolbarSearchKeepsFocusWhenFilteringHasNoResults() {
        let app = XCUIApplication()
        app.launchEnvironment["KEELOCKER_UI_TESTING"] = "1"
        app.launch()

        let searchField = app.descendants(matching: .any)["toolbar.search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))

        searchField.click()
        searchField.typeText("zzzz")

        let updatedSearchField = app.descendants(matching: .any)["toolbar.search"]
        XCTAssertTrue(waitForValue("focused|zzzz", on: updatedSearchField))
        XCTAssertTrue(app.staticTexts["No matching logins"].waitForExistence(timeout: 2))
    }

    private func waitForFocusState(
        _ state: String,
        on element: XCUIElement,
        timeout: TimeInterval = 2
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value BEGINSWITH %@", "\(state)|"),
            object: element
        )

        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForValue(
        _ value: String,
        on element: XCUIElement,
        timeout: TimeInterval = 2
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )

        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
