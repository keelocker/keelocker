import XCTest

@MainActor
final class ToolbarHoverUITests: XCTestCase {
    func testKeePassXCExternalSaveUpdatesUIAndConflictReloadRecovers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("live-sync.kdbx")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("KeeLockerTests/Fixtures/interop.kdbx")
        try FileManager.default.copyItem(at: fixture, to: path)

        let app = XCUIApplication()
        app.launchArguments = ["--ignore-last-vault"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        let open = app.buttons["Open Vault…"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        let choose = app.buttons["OKButton"]
        XCTAssertTrue(choose.waitForExistence(timeout: 3))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = app.textFields["PathTextField"]
        XCTAssertTrue(pathField.waitForExistence(timeout: 3))
        pathField.click()
        app.typeKey("a", modifierFlags: .command)
        pathField.typeText(path.path)
        app.typeKey(.return, modifierFlags: [])
        choose.click()
        let password = app.secureTextFields["Master Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 3))
        password.click()
        password.typeText("fixture-password")
        app.buttons["Unlock"].click()
        XCTAssertTrue(app.buttons["Current vault: KeeLocker Integration Vault"].waitForExistence(timeout: 15))
        let search = app.toolbars.searchFields.firstMatch
        search.click()
        search.typeText("github")
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "GitHub тест 🔐,")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()
        XCTAssertTrue(app.staticTexts["developer@example.test"].waitForExistence(timeout: 3))
        search.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])

        try runKeePassXC(["edit", "-q", "-u", "xc-live-user", path.path, "Work/Shared/GitHub тест 🔐"])
        XCTAssertTrue(app.staticTexts["xc-live-user"].waitForExistence(timeout: 10))
        app.buttons["Edit"].click()
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.click()
        app.typeKey("a", modifierFlags: .command)
        title.typeText("Native live sync")
        app.buttons["Save"].click()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 10))
        let saved = try runKeePassXC(["show", "-q", path.path, "Work/Shared/Native live sync"])
        XCTAssertTrue(saved.contains("xc-live-user"))

        app.buttons["Edit"].click()
        title.click()
        app.typeKey("a", modifierFlags: .command)
        title.typeText("Local conflicting draft")
        try runKeePassXC(["edit", "-q", "-u", "xc-second-user", path.path, "Work/Shared/Native live sync"])
        app.buttons["Save"].click()
        let reload = app.buttons["Reload Latest"]
        XCTAssertTrue(reload.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Save Copy…"].exists)
        let conflict = XCTAttachment(screenshot: app.screenshot())
        conflict.name = "external-save-conflict-recovery"
        conflict.lifetime = .keepAlways
        add(conflict)
        reload.click()
        XCTAssertTrue(app.staticTexts["xc-second-user"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Native live sync"].exists)
        let refreshed = XCTAttachment(screenshot: app.screenshot())
        refreshed.name = "external-save-reloaded"
        refreshed.lifetime = .keepAlways
        add(refreshed)
    }

    @discardableResult
    private func runKeePassXC(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli")
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data("fixture-password\n".utf8))
        try input.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "KeePassXC fixture operation must succeed")
        return String(decoding: bytes, as: UTF8.self)
    }

    func testOpenRealVaultRetrySearchAndLock() {
        let app = XCUIApplication()
        app.launchArguments = ["--ignore-last-vault"]
        app.launch()
        app.activate()
        let open = app.buttons["Open Vault…"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        let choose = app.buttons["OKButton"]
        XCTAssertTrue(choose.waitForExistence(timeout: 3))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = app.textFields["PathTextField"]
        XCTAssertTrue(pathField.waitForExistence(timeout: 3))
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("KeeLockerTests/Fixtures/interop.kdbx").path
        pathField.click()
        app.typeKey("a", modifierFlags: .command)
        pathField.typeText(path)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(choose.waitForExistence(timeout: 3))
        choose.click()
        let password = app.secureTextFields["Master Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 3))
        password.click()
        app.typeText("wrong")
        app.buttons["Unlock"].click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Wrong password"))
            .firstMatch.waitForExistence(timeout: 15))
        password.click()
        app.typeText("fixture-password")
        app.buttons["Unlock"].click()
        let vault = app.buttons["Current vault: KeeLocker Integration Vault"]
        XCTAssertTrue(vault.waitForExistence(timeout: 15))
        XCTAssertTrue(app.toolbars.buttons["toolbar.add"].isEnabled)
        let search = app.toolbars.searchFields.firstMatch
        search.click()
        app.typeText("github")
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "GitHub тест 🔐,")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()
        XCTAssertTrue(app.staticTexts["developer@example.test"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Edit"].isEnabled)
        app.buttons["Show"].click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "pässword-🔐-test"))
            .firstMatch.waitForExistence(timeout: 3))
        app.buttons["Lock vault"].click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "KeeLocker is locked"))
            .firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["developer@example.test"].exists)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNativeToolbarActionsRespondToHover() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault"]
        app.launch()
        app.activate()

        // A glass-decorated overlay is not a toolbar control and misses its hover behavior.
        let sortButton = app.toolbars.menuButtons["toolbar.sort"]
        let addButton = app.toolbars.buttons["toolbar.add"]
        XCTAssertTrue(sortButton.waitForExistence(timeout: 3))
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        let title = app.toolbars.groups["toolbar.listTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))

        for (name, button) in [("sort", sortButton), ("add", addButton)] {
            title.hover()
            let idle = button.screenshot()
            button.hover()
            let hovered = button.screenshot()
            for (state, screenshot) in [("idle", idle), ("hover", hovered)] {
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = "\(name)-\(state)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTAssertNotEqual(
                idle.pngRepresentation,
                hovered.pngRepresentation,
                "\(name) must visibly respond to pointer hover"
            )
        }
    }

    func testToolbarDoesNotExposeHoverProbeToAccessibility() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault"]
        app.launch()

        let sortButton = app.menuButtons["toolbar.sort"]
        let addButton = app.buttons["toolbar.add"]
        XCTAssertTrue(sortButton.waitForExistence(timeout: 3))
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        XCTAssertEqual(sortButton.value as? String, "")
        XCTAssertEqual(addButton.value as? String, "")
    }

    func testToolbarGeometryAndActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault"]
        app.launch()

        let sortButton = app.menuButtons["toolbar.sort"]
        let addButton = app.buttons["toolbar.add"]
        let detailSplitter = app.splitters.element(boundBy: 1)
        XCTAssertTrue(sortButton.waitForExistence(timeout: 3))
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        XCTAssertTrue(detailSplitter.waitForExistence(timeout: 3))
        // Native menu and button accessibility hit areas can overlap slightly.
        XCTAssertLessThan(sortButton.frame.midX, addButton.frame.midX)
        XCTAssertEqual(sortButton.frame.midY, addButton.frame.midY, accuracy: 1)
        XCTAssertLessThan(addButton.frame.maxX, detailSplitter.frame.minX)
        let trailingInset = assertActionsAlignToTrailingEdge(in: app, splitter: detailSplitter)

        resizeColumn(using: detailSplitter)
        assertActionsAlignToTrailingEdge(in: app, splitter: detailSplitter, expectedInset: trailingInset)

        addButton.hover()
        sortButton.hover()

        XCTAssertTrue(sortButton.isHittable)
        XCTAssertTrue(addButton.isHittable)
        sortButton.click()
        let sortBy = app.menuItems["Sort by"]
        XCTAssertTrue(sortBy.waitForExistence(timeout: 2))
        sortBy.hover()
        let titleOrder = app.menuItems["Title"]
        XCTAssertTrue(titleOrder.waitForExistence(timeout: 2))
        titleOrder.click()
        let airFrance = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Air France,")).firstMatch
        let appleID = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Apple ID,")).firstMatch
        let alphabeticalOrder = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                airFrance.exists && appleID.exists && airFrance.frame.minY < appleID.frame.minY
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter().wait(for: [alphabeticalOrder], timeout: 2), .completed)

        addButton.click()
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["9 logins"].exists)
        XCTAssertFalse(app.staticTexts["10 logins"].exists)
        app.buttons["Save"].click()
        XCTAssertTrue(app.staticTexts["10 logins"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["New login"].waitForExistence(timeout: 2))
    }

    func testListTitleLivesInsideToolbar() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault"]
        app.launch()

        let listTitle = app.toolbars.groups["toolbar.listTitle"]
        let sortButton = app.toolbars.menuButtons["toolbar.sort"]
        XCTAssertTrue(listTitle.waitForExistence(timeout: 3))
        XCTAssertTrue(sortButton.waitForExistence(timeout: 3))
        XCTAssertEqual(listTitle.frame.midY, sortButton.frame.midY, accuracy: 1)
        XCTAssertLessThan(listTitle.frame.maxX, sortButton.frame.minX)
    }

    func testListTitleClearsSidebarToggleWhenSidebarIsHidden() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault"]
        app.launch()

        let favoritesButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Favorites")
        ).firstMatch
        XCTAssertTrue(favoritesButton.waitForExistence(timeout: 3))
        favoritesButton.click()

        let sidebarToggle = app.toolbars.buttons.firstMatch
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 3))
        sidebarToggle.click()

        let listTitle = app.groups["toolbar.listTitle"]
        let sortButton = app.toolbars.menuButtons["toolbar.sort"]
        XCTAssertTrue(listTitle.waitForExistence(timeout: 3))
        XCTAssertTrue(sortButton.waitForExistence(timeout: 3))
        XCTAssertTrue(listTitle.isHittable)
        XCTAssertGreaterThanOrEqual(listTitle.frame.minX, sidebarToggle.frame.maxX + 2)
        XCTAssertLessThan(listTitle.frame.maxX, sortButton.frame.minX)
        XCTAssertEqual(listTitle.frame.midY, sortButton.frame.midY, accuracy: 1)

        let detailSplitter = app.splitters.firstMatch
        XCTAssertTrue(detailSplitter.waitForExistence(timeout: 3))
        let trailingInset = assertActionsAlignToTrailingEdge(in: app, splitter: detailSplitter)
        resizeColumn(using: detailSplitter)
        XCTAssertGreaterThan(sortButton.frame.minX, listTitle.frame.maxX)
        XCTAssertLessThan(app.toolbars.buttons["toolbar.add"].frame.maxX, detailSplitter.frame.minX)
        assertActionsAlignToTrailingEdge(in: app, splitter: detailSplitter, expectedInset: trailingInset)

        sidebarToggle.click()

        let expandedTitle = app.groups["toolbar.listTitle"]
        let sidebarSplitter = app.splitters.element(boundBy: 0)
        XCTAssertTrue(expandedTitle.waitForExistence(timeout: 3))
        XCTAssertTrue(sidebarSplitter.waitForExistence(timeout: 3))
        XCTAssertEqual(app.groups.matching(identifier: "toolbar.listTitle").count, 1)
        XCTAssertGreaterThan(expandedTitle.frame.minX, sidebarSplitter.frame.maxX)
        XCTAssertLessThan(expandedTitle.frame.maxX, sortButton.frame.minX)
        assertActionsAlignToTrailingEdge(
            in: app, splitter: app.splitters.element(boundBy: 1), expectedInset: trailingInset
        )
    }

    func testToolbarSearchAlignsWithNativeActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault"]
        app.launch()

        let searchField = app.toolbars.searchFields.firstMatch
        let addButton = app.toolbars.buttons["toolbar.add"]
        let detailSplitter = app.splitters.element(boundBy: 1)
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        XCTAssertTrue(detailSplitter.waitForExistence(timeout: 3))
        XCTAssertEqual(searchField.frame.midY, addButton.frame.midY, accuracy: 1)
        XCTAssertGreaterThan(searchField.frame.minX, detailSplitter.frame.maxX)
    }

    func testDraggingListDividerInTitlebarResizesColumnWithoutMovingWindow() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault"]
        app.launch()

        assertTitlebarDividerResizesColumnWithoutMovingWindow(
            in: app,
            splitter: app.splitters.element(boundBy: 1)
        )

        let window = app.windows.firstMatch
        let listTitle = app.groups["toolbar.listTitle"]
        let splitter = app.splitters.element(boundBy: 1)
        let originalWindowFrame = window.frame
        let originalDividerOffset = splitter.frame.midX - originalWindowFrame.minX
        let blankTitlebar = window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(
                dx: splitter.frame.midX + 70 - originalWindowFrame.minX,
                dy: listTitle.frame.midY - originalWindowFrame.minY
            )
        )
        blankTitlebar.hover()
        blankTitlebar.press(
            forDuration: 0.1,
            thenDragTo: blankTitlebar.withOffset(CGVector(dx: 30, dy: 0))
        )
        XCTAssertGreaterThan(window.frame.minX, originalWindowFrame.minX + 20)
        XCTAssertEqual(splitter.frame.midX - window.frame.minX, originalDividerOffset, accuracy: 1)
    }

    func testDraggingListDividerInTitlebarWhenSidebarIsHidden() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault"]
        app.launch()

        let sidebarToggle = app.toolbars.buttons.firstMatch
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 3))
        sidebarToggle.click()

        assertTitlebarDividerResizesColumnWithoutMovingWindow(
            in: app,
            splitter: app.splitters.firstMatch
        )
    }

    func testDraggingSidebarDividerInTitlebarResizesColumnWithoutMovingWindow() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault"]
        app.launch()

        assertTitlebarDividerResizesColumnWithoutMovingWindow(
            in: app,
            splitter: app.splitters.element(boundBy: 0)
        )
    }

    func testDividerClickClearsSearchFocus() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault"]
        app.launch()

        let searchField = app.toolbars.searchFields.firstMatch
        let listTitle = app.groups["toolbar.listTitle"]
        let splitter = app.splitters.element(boundBy: 1)
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        XCTAssertTrue(listTitle.waitForExistence(timeout: 3))
        XCTAssertTrue(splitter.waitForExistence(timeout: 3))

        searchField.click()
        app.typeText("151")
        XCTAssertTrue(waitForValue("151", on: searchField))

        let window = app.windows.firstMatch
        let divider = window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(
                dx: splitter.frame.midX + 3 - window.frame.minX,
                dy: listTitle.frame.midY - window.frame.minY
            )
        )
        divider.hover()
        divider.click()

        app.typeText("x")
        XCTAssertTrue(waitForValue("151", on: searchField))
    }

    func testWindowCanMoveAfterDividerHitsMaximumWidth() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault"]
        app.launch()

        let window = app.windows.firstMatch
        let splitter = app.splitters.element(boundBy: 1)
        let listTitle = app.groups["toolbar.listTitle"]
        XCTAssertTrue(splitter.waitForExistence(timeout: 3))
        XCTAssertTrue(listTitle.waitForExistence(timeout: 3))

        let initialWindowFrame = window.frame
        let initialDividerX = splitter.frame.midX
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(
                dx: initialDividerX + 3 - initialWindowFrame.minX,
                dy: listTitle.frame.midY - initialWindowFrame.minY
            )
        )
        let end = start.withOffset(CGVector(dx: 120, dy: 0))
        start.hover()
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertEqual(window.frame.minX, initialWindowFrame.minX, accuracy: 1)
        XCTAssertGreaterThan(initialDividerX + 123 - splitter.frame.midX, 6)

        end.press(forDuration: 0.1, thenDragTo: end.withOffset(CGVector(dx: 30, dy: 0)))
        XCTAssertGreaterThan(window.frame.minX, initialWindowFrame.minX + 20)
    }

    private func assertTitlebarDividerResizesColumnWithoutMovingWindow(
        in app: XCUIApplication,
        splitter: XCUIElement
    ) {
        let window = app.windows.firstMatch
        let listTitle = app.groups["toolbar.listTitle"]
        XCTAssertTrue(listTitle.waitForExistence(timeout: 3))
        XCTAssertTrue(splitter.waitForExistence(timeout: 3))

        let contentDivider = splitter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        contentDivider.press(
            forDuration: 0.1,
            thenDragTo: contentDivider.withOffset(CGVector(dx: -35, dy: 0))
        )

        let originalWindowFrame = window.frame
        let originalDividerX = splitter.frame.midX
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(
                dx: originalDividerX + 3 - originalWindowFrame.minX,
                dy: listTitle.frame.midY - originalWindowFrame.minY
            )
        )
        start.hover()
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 30, dy: 0)))

        XCTAssertEqual(window.frame.minX, originalWindowFrame.minX, accuracy: 1)
        XCTAssertEqual(window.frame.minY, originalWindowFrame.minY, accuracy: 1)
        XCTAssertGreaterThan(splitter.frame.midX, originalDividerX + 10)
    }

    func testNativeToolbarSearchClearAndEscape() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault"]
        app.launch()

        let searchField = app.toolbars.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.click()
        app.typeText("151")
        XCTAssertTrue(app.staticTexts["1 login"].waitForExistence(timeout: 2))

        let clearButton = searchField.buttons["cancel"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 2))
        clearButton.click()
        XCTAssertTrue(waitForValue("", on: searchField))
        XCTAssertTrue(app.staticTexts["9 logins"].waitForExistence(timeout: 2))

        searchField.click()
        app.typeText("0000")
        XCTAssertTrue(app.staticTexts["No matching logins"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForValue("", on: searchField))
        XCTAssertTrue(app.staticTexts["9 logins"].waitForExistence(timeout: 2))
        app.typeText("x")
        XCTAssertTrue(waitForValue("", on: searchField))
    }

    func testToolbarSearchKeepsFocusWhenFilteringHidesCurrentSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault"]
        app.launch()

        let searchField = app.toolbars.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))

        searchField.click()
        app.typeText("1")
        XCTAssertTrue(waitForValue("1", on: searchField))
        app.typeText("51")

        let updatedSearchField = app.toolbars.searchFields.firstMatch
        XCTAssertTrue(
            waitForValue("151", on: updatedSearchField),
            "Actual search value: \(String(describing: updatedSearchField.value))"
        )
        XCTAssertTrue(app.staticTexts["1 login"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Select a login"].waitForExistence(timeout: 2))
    }

    func testToolbarSearchKeepsFocusWhenFilteringHasNoResults() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault"]
        app.launch()

        let searchField = app.toolbars.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))

        searchField.click()
        app.typeText("000")
        XCTAssertTrue(app.staticTexts["No matching logins"].waitForExistence(timeout: 2))
        app.typeText("0")

        let updatedSearchField = app.toolbars.searchFields.firstMatch
        XCTAssertTrue(
            waitForValue("0000", on: updatedSearchField),
            "Actual search value: \(String(describing: updatedSearchField.value))"
        )
        XCTAssertTrue(app.staticTexts["No matching logins"].waitForExistence(timeout: 2))
    }

    private func resizeColumn(
        using splitter: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let initialX = splitter.frame.midX
        let divider = splitter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        divider.press(forDuration: 0.1, thenDragTo: divider.withOffset(CGVector(dx: 60, dy: 0)))
        // The restored column may already be at its maximum width.
        if abs(splitter.frame.midX - initialX) <= 10 {
            let currentDivider = splitter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            currentDivider.press(
                forDuration: 0.1,
                thenDragTo: currentDivider.withOffset(CGVector(dx: -60, dy: 0))
            )
        }
        XCTAssertGreaterThan(abs(splitter.frame.midX - initialX), 10, file: file, line: line)
    }

    @discardableResult
    private func assertActionsAlignToTrailingEdge(
        in app: XCUIApplication,
        splitter: XCUIElement,
        expectedInset: CGFloat? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGFloat {
        let addButton = app.toolbars.buttons["toolbar.add"]
        // AppKit's accessibility hit frame extends beyond the visible toolbar item.
        // Check proximity to the divider, then preserve that inset across layout changes.
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let inset = splitter.frame.minX - addButton.frame.maxX
                if let expectedInset {
                    return abs(inset - expectedInset) <= 1.5
                }
                return (0...16).contains(inset)
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: 3),
            .completed,
            "Toolbar actions must stay at the list's trailing edge with a stable inset. "
                + "Divider: \(splitter.frame), add: \(addButton.frame)",
            file: file,
            line: line
        )
        return splitter.frame.minX - addButton.frame.maxX
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
