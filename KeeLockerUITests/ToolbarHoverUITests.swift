import XCTest
import AppKit
import Carbon

@MainActor
final class ToolbarHoverUITests: XCTestCase {
    func testRecoveryCopyAndRecycleBinNativeFlow() throws {
        let previousInput = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let asciiInput = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        XCTAssertEqual(TISSelectInputSource(asciiInput), noErr)
        defer { TISSelectInputSource(previousInput) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("native-safety.kdbx")
        let destination = directory.appendingPathComponent("recovered.kdbx")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("KeeLockerTests/Fixtures/interop.kdbx")
        try FileManager.default.copyItem(at: fixture, to: source)
        let originalBytes = try Data(contentsOf: source)
        let app = XCUIApplication()
        app.launchArguments = ["--ignore-last-vault", "--disable-touch-id", "-automaticallyDownloadWebsiteIcons", "NO"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Open Vault…"].waitForExistence(timeout: 5))
        app.buttons["Open Vault…"].click()
        let choose = app.buttons["OKButton"]
        XCTAssertTrue(choose.waitForExistence(timeout: 3))
        app.outlines["ListView"].click()
        app.typeText("/")
        let path = app.textFields["PathTextField"]
        XCTAssertTrue(path.waitForExistence(timeout: 3))
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeText(source.path)
        path.typeKey(.return, modifierFlags: [])
        choose.click()
        let password = app.secureTextFields["Master Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 3))
        password.typeText("fixture-password")
        app.buttons["Unlock"].click()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 15))
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "GitHub тест 🔐,")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.rightClick()
        app.menuItems["Delete"].click()
        let trash = app.buttons["Move to Recycle Bin"]
        XCTAssertTrue(trash.waitForExistence(timeout: 3))
        trash.click()
        let bin = app.descendants(matching: .any).matching(identifier: "sidebar.recycleBin").firstMatch
        XCTAssertTrue(bin.waitForExistence(timeout: 10))
        bin.click()
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.rightClick()
        XCTAssertTrue(app.menuItems["Restore"].waitForExistence(timeout: 3))
        app.menuItems["Restore"].click()
        app.buttons["All items"].click()
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        let restored = try runKeePassXC(["show", "-q", source.path, "Work/Shared/GitHub тест 🔐"])
        XCTAssertTrue(restored.contains("developer@example.test"))

        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Recovery Copies…"].click()
        let original = app.descendants(matching: .any).matching(identifier: "recovery.original").firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.click()
        let recoveryPassword = app.secureTextFields["recovery.password"]
        XCTAssertTrue(recoveryPassword.waitForExistence(timeout: 3))
        recoveryPassword.click()
        recoveryPassword.typeText("fixture-password")
        let normal = XCTAttachment(screenshot: app.screenshot())
        normal.name = "recovery-copies-normal"
        normal.lifetime = .keepAlways
        add(normal)
        app.buttons["recovery.restore"].click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(path.waitForExistence(timeout: 3))
        path.click()
        app.typeKey("a", modifierFlags: .command)
        path.typeText(destination.path)
        app.typeKey(.return, modifierFlags: [])
        let save = app.buttons["Restore Copy"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.click()
        let copied = expectation(for: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: destination.path)
        }, evaluatedWith: nil)
        wait(for: [copied], timeout: 15)
        XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
        XCTAssertNotEqual(try Data(contentsOf: source), originalBytes)
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -200, dy: -80)))
        XCTAssertTrue(app.buttons["recovery.done"].isHittable)
        let minimum = XCTAttachment(screenshot: app.screenshot())
        minimum.name = "recovery-copies-small-window"
        minimum.lifetime = .keepAlways
        add(minimum)
        app.buttons["recovery.done"].click()
    }

    func testWebsiteIconControlsAndSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault", "--ignore-last-vault", "-automaticallyDownloadWebsiteIcons", "NO"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        app.buttons["entry.changeIcon"].click()
        let download = app.buttons["icon.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 3))
        XCTAssertTrue(download.isEnabled)
        XCTAssertTrue(app.buttons["icon.import"].exists)
        let picker = XCTAttachment(screenshot: app.screenshot())
        picker.name = "website-icon-picker"
        picker.lifetime = .keepAlways
        add(picker)
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["Cancel"].click()
        app.typeKey("n", modifierFlags: .command)
        app.buttons["entry.changeIcon"].click()
        XCTAssertTrue(download.waitForExistence(timeout: 3))
        XCTAssertFalse(download.isEnabled)
        XCTAssertTrue(app.staticTexts["Add a website to download its icon."].exists)
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["Cancel"].click()
        app.typeKey(",", modifierFlags: .command)
        let automatic = app.switches["settings.automaticWebsiteIcons"]
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        XCTAssertFalse(["1", "on"].contains(automatic.value as? String ?? ""))
        let settings = XCTAttachment(screenshot: app.screenshot())
        settings.name = "website-icon-settings"
        settings.lifetime = .keepAlways
        add(settings)
    }

    func testEntryIconImportCancelSaveAndReuse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Synthetic Icon.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<64 {
            for x in 0..<64 {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = 217
                pixels[offset + 1] = 51
                pixels[offset + 2] = 128
                pixels[offset + 3] = 255
            }
        }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault", "--ignore-last-vault"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        let change = app.buttons["entry.changeIcon"]
        let original = change.value as? String

        func importIcon() {
            change.click()
            let add = app.buttons["icon.import"]
            XCTAssertTrue(add.waitForExistence(timeout: 3))
            add.click()
            let choose = app.buttons["OKButton"]
            XCTAssertTrue(choose.waitForExistence(timeout: 3))
            app.searchFields["Search"].click()
            app.typeKey("g", modifierFlags: [.command, .shift])
            let path = app.textFields["PathTextField"]
            XCTAssertTrue(path.waitForExistence(timeout: 3))
            path.click()
            app.typeKey("a", modifierFlags: .command)
            path.typeText(url.path)
            app.typeKey(.return, modifierFlags: [])
            let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: choose)
            wait(for: [ready], timeout: 5)
            choose.click()
            let imported = expectation(for: NSPredicate(format: "value == %@", "Synthetic Icon"), evaluatedWith: change)
            wait(for: [imported], timeout: 5)
        }

        importIcon()
        app.buttons["Cancel"].click()
        edit.click()
        XCTAssertEqual(change.value as? String, original)
        importIcon()
        app.buttons["Save"].click()
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.click()
        change.click()
        let search = app.textFields["icon.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click()
        search.typeText("Synthetic Icon")
        let stored = app.buttons["Synthetic Icon"]
        XCTAssertTrue(stored.waitForExistence(timeout: 3))
        stored.click()
        XCTAssertEqual(change.value as? String, "Synthetic Icon")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "entry-imported-icon"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Cancel"].click()
    }

    func testEntryIconPickerSearchSaveAndCancel() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault", "--ignore-last-vault"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        let change = app.buttons["entry.changeIcon"]
        XCTAssertTrue(change.waitForExistence(timeout: 3))
        change.click()
        let search = app.textFields["icon.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        app.activate()
        search.click()
        search.typeText("Email")
        let filtered = expectation(for: NSPredicate(format: "value == %@", "Email"), evaluatedWith: search)
        wait(for: [filtered], timeout: 3)
        let email = app.buttons["icon.standard.19"]
        XCTAssertTrue(email.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["icon.standard.64"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "entry-icon-picker"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        email.click()
        XCTAssertEqual(change.value as? String, "Email")
        app.buttons["Save"].click()
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.click()
        XCTAssertEqual(change.value as? String, "Email")
        change.click()
        let appleSearch = app.textFields["icon.search"]
        XCTAssertTrue(appleSearch.waitForExistence(timeout: 3))
        appleSearch.click()
        appleSearch.typeText("Apple")
        let apple = app.buttons["icon.standard.64"]
        XCTAssertTrue(apple.waitForExistence(timeout: 3))
        apple.click()
        XCTAssertEqual(change.value as? String, "Apple")
        app.buttons["Cancel"].click()
        edit.click()
        XCTAssertEqual(change.value as? String, "Email")
        app.buttons["Cancel"].click()
    }

    func testKeePassXCExternalSaveUpdatesUIAndConflictReloadRecovers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("live-sync.kdbx")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("KeeLockerTests/Fixtures/interop.kdbx")
        try FileManager.default.copyItem(at: fixture, to: path)

        let app = XCUIApplication()
        app.launchArguments = ["--ignore-last-vault", "--disable-touch-id"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        let open = app.buttons["Open Vault…"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        let choose = app.buttons["OKButton"]
        XCTAssertTrue(choose.waitForExistence(timeout: 3))
        app.searchFields["Search"].click()
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
        app.launchArguments = ["--ignore-last-vault", "--disable-touch-id"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        let open = app.buttons["Open Vault…"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        let choose = app.buttons["OKButton"]
        XCTAssertTrue(choose.waitForExistence(timeout: 3))
        app.searchFields["Search"].click()
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
        XCTAssertTrue(app.staticTexts["Wrong password"].waitForExistence(timeout: 15))
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
        XCTAssertTrue(app.staticTexts["pässword-🔐-test"].waitForExistence(timeout: 3))
        app.buttons["Lock vault"].click()
        XCTAssertTrue(app.staticTexts["KeeLocker is locked"].waitForExistence(timeout: 3))
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

    func testListTitleClearsSidebarToggleWhenSidebarIsHidden() throws {
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

        let detailSplitter = try visibleListDivider(in: app)
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

    func testDraggingListDividerInTitlebarWhenSidebarIsHidden() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-vault"]
        app.launch()

        let sidebarToggle = app.toolbars.buttons.firstMatch
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 3))
        sidebarToggle.click()

        assertTitlebarDividerResizesColumnWithoutMovingWindow(
            in: app,
            splitter: try visibleListDivider(in: app)
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

    private func visibleListDivider(in app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        XCTAssertTrue(app.splitters.firstMatch.waitForExistence(timeout: 3))
        // AppKit can retain the collapsed sidebar divider in AX at the window
        // edge. The list/detail divider is the rightmost interior divider.
        let interior = app.splitters.allElementsBoundByIndex.filter {
            let frame = $0.frame
            return frame.height > 0 && frame.midX > window.frame.minX + 20
                && frame.midX < window.frame.maxX - 20
        }
        return try XCTUnwrap(interior.max { $0.frame.midX < $1.frame.midX },
                             "No visible list/detail divider inside the window")
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
