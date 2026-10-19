import XCTest
import AppKit
@testable import KeeLocker

@MainActor
final class FaviconTests: XCTestCase {
    private func entry(_ website: String = "https://icons.example/login?secret=synthetic") -> VaultItem {
        VaultItem(title: "Synthetic login", username: " synthetic user ", password: " synthetic password ",
                  website: website, notes: " Synthetic notes ", tags: ["synthetic"],
                  group: .personal, iconName: "key.fill", iconColor: .indigo, modifiedAt: .now)
    }

    private func image(size: Int = 16) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<size {
            for x in 0..<size {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = 80
                pixels[offset + 1] = 110
                pixels[offset + 2] = 210
                pixels[offset + 3] = 255
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testOriginRemovesStoredCredentialsAndPrivateURLParts() {
        XCTAssertEqual(FaviconDownloader.origin(for: " https://user:synthetic@EXAMPLE.com:8443/private?q=secret#fragment ")?.absoluteString,
                       "https://example.com:8443/")
        XCTAssertEqual(FaviconDownloader.origin(for: "http://example.com:8080/login")?.absoluteString, "https://example.com/")
        XCTAssertEqual(FaviconDownloader.origin(for: "example.com/login")?.absoluteString, "https://example.com/")
        for invalid in ["", "file:///tmp/icon.png", "ftp://example.com", "https:///", "https://bad host"] {
            XCTAssertNil(FaviconDownloader.origin(for: invalid), invalid)
        }
        for invalid in ["http://example.com/icon", "file:///tmp/icon.png", "https://user:pass@example.com/icon"] {
            XCTAssertFalse(FaviconDownloader.isAllowed(URL(string: invalid)!))
        }
    }

    func testHTMLDiscoveryUsesFinalPageURLAndRejectsUnsafeLinks() {
        let html = #"<link href='/assets/icon.png?size=64&amp;v=1' rel='shortcut icon'><link rel=apple-touch-icon href=//cdn.example/touch.png><link rel=stylesheet href='/styles.css'><link rel=icon href='file:///tmp/x'><link rel=icon href='https://user:pass@example.com/x'>"#
        XCTAssertEqual(FaviconDownloader.iconURLs(in: html, relativeTo: URL(string: "https://redirect.example/home")!).map(\.absoluteString),
                       ["https://cdn.example/touch.png", "https://redirect.example/assets/icon.png?size=64&v=1"])
    }

    func testHostileHTMLDiscoveryRemainsBounded() {
        let origin = URL(string: "https://icons.example/")!
        let html = "<link " + String(repeating: "a", count: 16_000) + ">"
        let start = ContinuousClock.now
        XCTAssertTrue(FaviconDownloader.iconURLs(in: html, relativeTo: origin).isEmpty)
        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(2), "Bounded HTML must not cause regex backtracking")
        let unfinished = String(repeating: "<link ", count: 32_000)
        let nextStart = ContinuousClock.now
        XCTAssertTrue(FaviconDownloader.iconURLs(in: unfinished, relativeTo: origin).isEmpty)
        XCTAssertLessThan(nextStart.duration(to: .now), .seconds(2))
    }

    func testMultiSizeICOPrefersLargestRepresentation() throws {
        let small = try image(size: 16)
        let large = try image(size: 64)
        var ico = Data([0, 0, 1, 0, 2, 0])
        func appendLE(_ value: UInt32) {
            ico.append(contentsOf: [UInt8(value & 255), UInt8((value >> 8) & 255),
                                   UInt8((value >> 16) & 255), UInt8((value >> 24) & 255)])
        }
        for (size, bytes, offset) in [(16, small, 38), (64, large, 38 + small.count)] {
            ico.append(contentsOf: [UInt8(size), UInt8(size), 0, 0, 1, 0, 32, 0])
            appendLE(UInt32(bytes.count))
            appendLE(UInt32(offset))
        }
        ico.append(small)
        ico.append(large)
        let imported = try IconImageImport.normalized(ico, name: "Synthetic multi-size icon")
        let preview = try XCTUnwrap(IconImageImport.preview(imported.data))
        XCTAssertEqual(preview.width, 64)
        XCTAssertEqual(preview.height, 64)
    }

    func testDownloadFindsImageAndNormalizesItWithoutSendingEntryURL() async throws {
        let png = try image()
        let transport = IconTestTransport(png: png)
        let downloader = FaviconDownloader { url, limit in try await transport.fetch(url, limit: limit) }
        let origin = try XCTUnwrap(FaviconDownloader.origin(for: "https://user:synthetic@icons.example/private?token=synthetic"))
        let icon = try await downloader.download(origin)
        XCTAssertEqual(icon.name, "icons.example")
        XCTAssertNotNil(IconImageImport.preview(icon.data))
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.absoluteString), ["https://icons.example/", "https://icons.example/site.png"])
    }

    func testFallbackWorksWhenHTMLIsUnavailableAndBadImagesFail() async throws {
        let png = try image()
        let downloader = FaviconDownloader { url, _ in
            if url.path == "/" { throw FaviconDownloader.Failure.unavailable }
            return FaviconResponse(data: png, url: url)
        }
        let downloaded = try await downloader.download(URL(string: "https://icons.example/")!)
        XCTAssertNotNil(IconImageImport.preview(downloaded.data))
        let bad = FaviconDownloader { url, _ in FaviconResponse(data: Data("not an image".utf8), url: url) }
        do {
            _ = try await bad.download(URL(string: "https://icons.example/")!)
            XCTFail("An invalid icon must not enter the vault")
        } catch { XCTAssertTrue(error is FaviconDownloader.Failure) }
    }

    func testOversizedResponsesAreRejectedAndDiscoveryIsBounded() async throws {
        let downloader = FaviconDownloader { url, limit in
            FaviconResponse(data: Data(repeating: 0, count: limit + 1), url: url)
        }
        do {
            _ = try await downloader.download(URL(string: "https://icons.example/")!)
            XCTFail("Oversized responses must be rejected")
        } catch { XCTAssertTrue(error is FaviconDownloader.Failure) }
        let html = (0..<100).map { "<link rel=icon href='/icon\($0).png'>" }.joined()
        XCTAssertEqual(FaviconDownloader.iconURLs(in: html, relativeTo: URL(string: "https://icons.example/")!).count, 5)
    }

    func testManualDownloadIsADraftAndInvalidationDiscardsLateResults() async throws {
        let gate = IconDownloadGate()
        let icon = VaultCustomIcon(id: UUID(), name: "Synthetic", data: try image())
        let session = IconImportSession(websiteLoader: { _ in await gate.load(icon) })
        let request = session.begin()
        let read = Task { try await session.loadWebsite(URL(string: "https://icons.example/")!, request: request) }
        await gate.waitUntilStarted()
        session.invalidate()
        await gate.release()
        let stale = try await read.value
        XCTAssertNil(stale)
        let repository = MemoryVaultRepository(items: [entry()])
        let store = VaultStore()
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        var draft = ItemEditingDraft(try XCTUnwrap(store.selectedEntry))
        draft.item.chooseIcon(.imported(icon))
        XCTAssertNil(repository.vault.entries.first?.icon)
        let saved = await store.saveItem(draft.savedItem)
        XCTAssertTrue(saved)
        XCTAssertEqual(repository.vault.entries.first?.icon, .custom(icon))
        store.lock()
    }

    func testAutomaticIsOptInFillsDefaultsAndReusesOneRequestPerOrigin() async throws {
        let loader = IconTestLoader(icon: VaultCustomIcon(id: UUID(), name: "Synthetic", data: try image()))
        var chosen = entry("https://chosen.example")
        chosen.icon = .builtIn(19)
        var custom = entry("https://custom.example")
        custom.icon = .custom(VaultCustomIcon(id: UUID(), name: "Chosen", data: Data([1])))
        var future = entry("https://future.example")
        future.icon = .builtIn(1234)
        var missing = entry()
        missing.icon = .builtIn(0)
        let second = entry("https://icons.example/another")
        let repository = MemoryVaultRepository(items: [missing, second, chosen, custom, future])
        let store = VaultStore(websiteIconLoader: { try await loader.load($0) })
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        await store.waitForAutomaticIcons()
        let initialRequests = await loader.requests
        XCTAssertTrue(initialRequests.isEmpty)
        store.setAutomaticIconDownloads(true)
        await store.waitForAutomaticIcons()
        let requests = await loader.requests
        XCTAssertEqual(requests, [URL(string: "https://icons.example/")!])
        XCTAssertEqual(repository.vault.customIcons.count, 1)
        XCTAssertFalse(repository.vault.entries[0].needsWebsiteIcon)
        XCTAssertFalse(repository.vault.entries[1].needsWebsiteIcon)
        XCTAssertEqual(repository.vault.entries[0].password, missing.password)
        XCTAssertEqual(repository.vault.entries[0].notes, missing.notes)
        XCTAssertEqual(repository.vault.entries[0].tags, missing.tags)
        XCTAssertEqual(repository.vault.entries[2].icon, chosen.icon)
        XCTAssertEqual(repository.vault.entries[3].icon, custom.icon)
        XCTAssertEqual(repository.vault.entries[4].icon, future.icon)
        store.lock()
    }

    func testAutomaticWaitsForDraftAndDownloadsAfterSaveAndNextOpen() async throws {
        let loader = IconTestLoader(icon: VaultCustomIcon(id: UUID(), name: "Synthetic", data: try image()))
        let repository = MemoryVaultRepository(items: [entry()])
        let store = VaultStore(websiteIconLoader: { try await loader.load($0) })
        store.setAutomaticIconDownloads(true)
        store.use(repository)
        store.hasDraft = true
        store.unlock()
        await store.waitForUnlock()
        await store.waitForAutomaticIcons()
        let initialRequests = await loader.requests
        XCTAssertTrue(initialRequests.isEmpty)
        store.hasDraft = false
        await store.waitForAutomaticIcons()
        XCTAssertNotNil(repository.vault.entries.first?.icon)
        store.addItem()
        var draft = try XCTUnwrap(store.newItemDraft)
        draft.website = "https://new.example/login"
        let saved = await store.saveItem(draft)
        XCTAssertTrue(saved)
        await store.waitForAutomaticIcons()
        XCTAssertNotNil(repository.vault.entries.first { $0.website == draft.website }?.icon)
        let next = MemoryVaultRepository(items: [entry("https://next.example")])
        store.use(next)
        store.unlock()
        await store.waitForUnlock()
        await store.waitForAutomaticIcons()
        XCTAssertNotNil(next.vault.entries.first?.icon)
        store.lock()
    }

    func testDisableAndSessionReplacementDiscardUncancellableDownloads() async throws {
        for replaceSession in [false, true] {
            let gate = IconDownloadGate()
            let icon = VaultCustomIcon(id: UUID(), name: "Synthetic", data: try image())
            let repository = MemoryVaultRepository(items: [entry()])
            let store = VaultStore(websiteIconLoader: { _ in await gate.load(icon) })
            store.use(repository)
            store.unlock()
            await store.waitForUnlock()
            store.setAutomaticIconDownloads(true)
            await gate.waitUntilStarted()
            if replaceSession {
                store.use(MemoryVaultRepository(items: [entry("https://replacement.example")]))
            } else { store.setAutomaticIconDownloads(false) }
            await gate.release()
            await gate.waitUntilReturned()
            await Task.yield()
            XCTAssertNil(repository.vault.entries.first?.icon)
            XCTAssertTrue(store.customIcons.isEmpty)
            XCTAssertNil(store.operationFailure)
            store.lock()
        }
    }

    func testChangedWebsiteAndManualChoiceWinOverInFlightAutomaticDownload() async throws {
        let gate = IconDownloadGate()
        let icon = VaultCustomIcon(id: UUID(), name: "Synthetic", data: try image())
        let repository = MemoryVaultRepository(items: [entry()])
        let store = VaultStore(websiteIconLoader: { _ in await gate.load(icon) })
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        store.setAutomaticIconDownloads(true)
        await gate.waitUntilStarted()
        var changed = try XCTUnwrap(store.selectedEntry)
        changed.website = "https://chosen.example/login"
        changed.title = "Changed while downloading"
        changed.chooseIcon(.builtIn(19))
        store.updateItem(changed)
        await store.waitForOperation()
        await gate.release()
        await store.waitForAutomaticIcons()
        XCTAssertEqual(repository.vault.entries.first?.icon, .builtIn(19))
        XCTAssertEqual(repository.vault.entries.first?.title, changed.title)
        XCTAssertEqual(repository.vault.entries.first?.website, changed.website)
        store.lock()
    }

    func testSavedFaviconRefreshesWhenWebsiteDomainChanges() async throws {
        let first = VaultCustomIcon(id: UUID(), name: "icons.example", data: try image(size: 16))
        let second = VaultCustomIcon(id: UUID(), name: "changed.example", data: try image(size: 32))
        let loader = WebsiteIconTestLoader(icons: ["icons.example": first, "changed.example": second])
        let repository = MemoryVaultRepository(items: [entry()])
        let store = VaultStore(websiteIconLoader: { try await loader.load($0) })
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        store.setAutomaticIconDownloads(true)
        await store.waitForAutomaticIcons()
        XCTAssertEqual(store.selectedEntry?.icon?.imageData, first.data)
        var changed = try XCTUnwrap(store.selectedEntry)
        changed.website = "https://changed.example/login"
        store.updateItem(changed)
        await store.waitForOperation()
        await store.waitForAutomaticIcons()
        XCTAssertEqual(store.selectedEntry?.website, changed.website)
        XCTAssertEqual(store.selectedEntry?.icon?.imageData, second.data)
        XCTAssertEqual(store.selectedEntry?.password, changed.password)
        // Path/query edits keep the same website icon. Switching back and forth
        // must use cached origins rather than being blocked by past attempts.
        for website in ["https://changed.example/other?query=synthetic",
                        "https://icons.example/login?secret=synthetic", "https://changed.example/login"] {
            changed = try XCTUnwrap(store.selectedEntry)
            changed.website = website
            store.updateItem(changed)
            await store.waitForOperation()
            await store.waitForAutomaticIcons()
            XCTAssertEqual(store.selectedEntry?.icon?.imageData,
                           website.contains("changed.example") ? second.data : first.data)
        }
        let requests = await loader.requests
        XCTAssertEqual(requests.map(\.host), ["icons.example", "changed.example"])
        store.lock()
    }

    func testManualCustomChoiceStopsFollowingWebsite() async throws {
        let downloaded = VaultCustomIcon(id: UUID(), name: "icons.example", data: try image())
        let loader = WebsiteIconTestLoader(icons: ["icons.example": downloaded])
        let repository = MemoryVaultRepository(items: [entry()])
        let store = VaultStore(websiteIconLoader: { try await loader.load($0) })
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        store.setAutomaticIconDownloads(true)
        await store.waitForAutomaticIcons()
        var selected = try XCTUnwrap(store.selectedEntry)
        XCTAssertNotNil(selected.websiteIconOrigin)
        selected.chooseIcon(try XCTUnwrap(selected.icon))
        store.updateItem(selected)
        await store.waitForOperation()
        selected = try XCTUnwrap(store.selectedEntry)
        XCTAssertNil(selected.websiteIconOrigin)
        selected.website = "https://changed.example/login"
        store.updateItem(selected)
        await store.waitForOperation()
        await store.waitForAutomaticIcons()
        XCTAssertEqual(store.selectedEntry?.icon, selected.icon)
        let requests = await loader.requests
        XCTAssertEqual(requests.map(\.host), ["icons.example"])
        store.lock()
    }

    func testNewerWebsiteWinsOverUncancellableFaviconRefresh() async throws {
        let first = VaultCustomIcon(id: UUID(), name: "icons.example", data: try image())
        let obsolete = VaultCustomIcon(id: UUID(), name: "obsolete.example", data: try image(size: 32))
        let latest = VaultCustomIcon(id: UUID(), name: "latest.example", data: try image(size: 64))
        let gate = IconDownloadGate()
        let repository = MemoryVaultRepository(items: [entry()])
        let store = VaultStore(websiteIconLoader: { origin in
            switch origin.host {
            case "icons.example": first
            case "obsolete.example": await gate.load(obsolete)
            default: latest
            }
        })
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        store.setAutomaticIconDownloads(true)
        await store.waitForAutomaticIcons()
        var changed = try XCTUnwrap(store.selectedEntry)
        changed.website = "https://obsolete.example/login"
        store.updateItem(changed)
        await store.waitForOperation()
        await gate.waitUntilStarted()
        store.hasDraft = true
        changed = try XCTUnwrap(store.selectedEntry)
        changed.website = "https://latest.example/login"
        store.updateItem(changed)
        await store.waitForOperation()
        store.hasDraft = false
        await store.waitForAutomaticIcons()
        await gate.release()
        await gate.waitUntilReturned()
        await Task.yield()
        XCTAssertEqual(store.selectedEntry?.website, changed.website)
        XCTAssertEqual(store.selectedEntry?.websiteIconOrigin?.host, "latest.example")
        XCTAssertEqual(store.selectedEntry?.icon?.imageData, latest.data)
        store.lock()
    }

    func testSupersededDownloadDoesNotBlockReturningToWebsiteAfterRefresh() async throws {
        let first = VaultCustomIcon(id: UUID(), name: "icons.example", data: try image())
        let second = VaultCustomIcon(id: UUID(), name: "changed.example", data: try image(size: 32))
        let gate = IconDownloadGate()
        let original = entry()
        let repository = RefreshableIconRepository(items: [original])
        let store = VaultStore(websiteIconLoader: { origin in
            if origin.host == "icons.example" { return await gate.load(first) }
            return second
        })
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        store.setAutomaticIconDownloads(true)
        await gate.waitUntilStarted()
        var external = original
        external.website = "https://changed.example/login"
        repository.base.replaceEntries([external])
        store.refreshFromDisk()
        await store.waitForRefresh()
        await gate.release()
        await store.waitForAutomaticIcons()
        XCTAssertEqual(store.selectedEntry?.icon?.imageData, second.data)
        var restored = try XCTUnwrap(store.selectedEntry)
        restored.website = original.website
        store.updateItem(restored)
        await store.waitForOperation()
        await store.waitForAutomaticIcons()
        XCTAssertEqual(store.selectedEntry?.website, original.website)
        XCTAssertEqual(store.selectedEntry?.icon?.imageData, first.data,
                       "An obsolete attempt must not suppress a later valid return to its Website")
        store.lock()
    }

    func testSuccessfulDownloadWaitsForUnchangedFileRefresh() async throws {
        let icon = VaultCustomIcon(id: UUID(), name: "Synthetic", data: try image())
        let gate = IconDownloadGate()
        let repository = RefreshableIconRepository(items: [entry()])
        let store = VaultStore(websiteIconLoader: { _ in await gate.load(icon) })
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        store.setAutomaticIconDownloads(true)
        await gate.waitUntilStarted()
        repository.suspendsRefresh = true
        store.refreshFromDisk()
        while repository.refreshContinuation == nil { await Task.yield() }
        XCTAssertTrue(store.isBusy)
        await gate.release()
        await store.waitForAutomaticIcons()
        repository.refreshContinuation?.resume(returning: nil)
        repository.refreshContinuation = nil
        await store.waitForRefresh()
        await store.waitForAutomaticIcons()
        XCTAssertEqual(store.selectedEntry?.icon?.imageData, icon.data)
        XCTAssertFalse(store.isBusy)
        store.lock()
    }

    func testRefreshWaitsForPreferenceAndPreservesOldIconOnNetworkFailure() async throws {
        let first = VaultCustomIcon(id: UUID(), name: "icons.example", data: try image())
        let loader = WebsiteIconTestLoader(icons: ["icons.example": first])
        let repository = MemoryVaultRepository(items: [entry()])
        let store = VaultStore(websiteIconLoader: { try await loader.load($0) })
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        store.setAutomaticIconDownloads(true)
        await store.waitForAutomaticIcons()
        store.setAutomaticIconDownloads(false)
        var changed = try XCTUnwrap(store.selectedEntry)
        changed.website = "https://unavailable.example/login"
        store.updateItem(changed)
        await store.waitForOperation()
        await store.waitForAutomaticIcons()
        let disabledRequests = await loader.requests
        XCTAssertEqual(disabledRequests.count, 1)
        XCTAssertEqual(store.selectedEntry?.icon?.imageData, first.data)
        store.setAutomaticIconDownloads(true)
        await store.waitForAutomaticIcons()
        let enabledRequests = await loader.requests
        XCTAssertEqual(enabledRequests.map(\.host), ["icons.example", "unavailable.example"])
        XCTAssertEqual(store.selectedEntry?.icon?.imageData, first.data)
        XCTAssertEqual(store.selectedEntry?.websiteIconOrigin?.host, "icons.example")
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.isDirty)
        store.lock()
    }

    func testManuallyDownloadedFaviconFollowsWebsiteAfterKDBXReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("website-change.kdbx")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/interop.kdbx")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let first = VaultCustomIcon(id: UUID(), name: "icons.example", data: try image())
        let second = VaultCustomIcon(id: UUID(), name: "changed.example", data: try image(size: 32))
        let loader = WebsiteIconTestLoader(icons: ["changed.example": second])
        let store = VaultStore(websiteIconLoader: { try await loader.load($0) })
        store.openFile(copy)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        store.addItem()
        var draft = try XCTUnwrap(store.newItemDraft)
        draft.title = "Synthetic website change"
        draft.website = "https://icons.example/private?query=synthetic"
        draft.password = " Synthetic password "
        draft.useWebsiteIcon(first, origin: URL(string: "https://icons.example/")!)
        let created = await store.saveItem(draft)
        XCTAssertTrue(created)
        let id = try XCTUnwrap(store.selectedItemID)
        store.lock()
        store.openFile(copy)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        store.selectedItemID = id
        await store.waitForSelection()
        var changed = try XCTUnwrap(store.selectedEntry)
        XCTAssertEqual(changed.websiteIconOrigin?.absoluteString, "https://icons.example/")
        store.setAutomaticIconDownloads(true)
        await store.waitForAutomaticIcons()
        let unchangedRequests = await loader.requests
        XCTAssertFalse(unchangedRequests.contains { $0.host == "icons.example" })
        changed.website = "https://changed.example/login"
        store.updateItem(changed)
        await store.waitForOperation()
        await store.waitForAutomaticIcons()
        XCTAssertEqual(store.selectedEntry?.icon?.imageData, second.data)
        XCTAssertEqual(store.selectedEntry?.websiteIconOrigin?.absoluteString, "https://changed.example/")
        let history = try await store.history(id)
        XCTAssertTrue(history.contains { $0.websiteIconOrigin?.host == "icons.example" && $0.icon?.imageData == first.data })
        store.lock()
        let reopened = RustVaultRepository(url: copy)
        _ = try await reopened.load(password: "fixture-password", keyFile: nil)
        defer { reopened.lock() }
        let persisted = try await reopened.entry(id)
        XCTAssertEqual(persisted.icon?.imageData, second.data)
        XCTAssertEqual(persisted.websiteIconOrigin?.host, "changed.example")
        XCTAssertEqual(persisted.password, draft.password)
        // Selecting that same custom UUID explicitly freezes it, even after reopen.
        var manual = persisted
        manual.chooseIcon(try XCTUnwrap(persisted.icon))
        _ = try await reopened.execute(.updateEntry(manual))
        reopened.lock()
        _ = try await reopened.load(password: "fixture-password", keyFile: nil)
        let frozen = try await reopened.entry(id)
        XCTAssertNil(frozen.websiteIconOrigin)
        XCTAssertEqual(frozen.icon, persisted.icon)
    }

    func testFailedOriginIsQuietAndRetriedOnlyAfterReenable() async throws {
        let loader = FailingIconLoader()
        let repository = MemoryVaultRepository(items: [entry(), entry("https://icons.example/second")])
        let store = VaultStore(websiteIconLoader: { try await loader.load($0) })
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        store.setAutomaticIconDownloads(true)
        await store.waitForAutomaticIcons()
        let initialCount = await loader.count
        XCTAssertEqual(initialCount, 1)
        XCTAssertNil(store.operationFailure)
        XCTAssertTrue(repository.vault.entries.allSatisfy { $0.icon == nil })
        store.setAutomaticIconDownloads(false)
        store.setAutomaticIconDownloads(true)
        await store.waitForAutomaticIcons()
        let retriedCount = await loader.count
        XCTAssertEqual(retriedCount, 2)
        store.lock()
    }

    func testManyEntriesAtFailedOriginAreSkippedWithoutRepeatedScanning() async {
        let loader = FailingIconLoader()
        let entries = (0..<2_000).map { entry("https://icons.example/login/\($0)") }
        let repository = MemoryVaultRepository(items: entries)
        let store = VaultStore(websiteIconLoader: { try await loader.load($0) })
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        let start = ContinuousClock.now
        store.setAutomaticIconDownloads(true)
        await store.waitForAutomaticIcons()
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let requests = await loader.count
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(repository.vault.entries.count, entries.count)
        XCTAssertTrue(repository.vault.entries.allSatisfy { $0.icon == nil })
        store.lock()
    }

    func testExplicitDefaultIconSurvivesWebsiteChangeAndKDBXReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("manual-key.kdbx")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/interop.kdbx")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let icon = VaultCustomIcon(id: UUID(), name: "Synthetic", data: try image())
        let store = VaultStore(websiteIconLoader: { _ in icon })
        store.openFile(copy)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        store.addItem()
        var draft = try XCTUnwrap(store.newItemDraft)
        draft.website = "https://manual.example/login"
        draft.chooseIcon(.builtIn(0))
        let created = await store.saveItem(draft)
        XCTAssertTrue(created)
        let id = try XCTUnwrap(store.selectedItemID)
        store.setAutomaticIconDownloads(true)
        await store.waitForAutomaticIcons()
        XCTAssertEqual(store.selectedEntry?.icon, .builtIn(0))
        var changed = try XCTUnwrap(store.selectedEntry)
        changed.website = "https://changed.example/login"
        store.updateItem(changed)
        await store.waitForOperation()
        await store.waitForAutomaticIcons()
        XCTAssertEqual(store.selectedEntry?.icon, .builtIn(0), "A URL edit must retain a manually selected key")
        store.lock()
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        await store.waitForAutomaticIcons()
        store.selectedItemID = id
        await store.waitForSelection()
        XCTAssertEqual(store.selectedEntry?.icon, .builtIn(0), "Reopen must preserve the manual choice")
        store.lock()
    }

    func testAutomaticIconPersistsInKDBXWithFieldsAndHistoryIntact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("synthetic.kdbx")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/interop.kdbx")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let png = try image()
        let downloader = FaviconDownloader { url, _ in
            guard url.host == "icons.example" else { throw FaviconDownloader.Failure.unavailable }
            if url.path == "/" { return FaviconResponse(data: Data("<link rel=icon href='/site.png'>".utf8), url: url) }
            return FaviconResponse(data: png, url: url)
        }
        let store = VaultStore(websiteIconLoader: { try await downloader.download($0) })
        store.openFile(copy)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        store.addItem()
        var draft = try XCTUnwrap(store.newItemDraft)
        draft.title = "Synthetic favicon login"
        draft.website = "https://icons.example/private?token=synthetic"
        draft.username = " Synthetic user "
        draft.password = " Synthetic password "
        draft.notes = " Synthetic notes "
        draft.tags = ["favicon-test"]
        draft.isFavorite = true
        let created = await store.saveItem(draft)
        XCTAssertTrue(created)
        let id = try XCTUnwrap(store.selectedItemID)
        store.setAutomaticIconDownloads(true)
        await store.waitForAutomaticIcons()
        let result = try XCTUnwrap(store.selectedEntry)
        XCTAssertNotNil(result.icon?.imageData)
        XCTAssertEqual(result.password, draft.password)
        XCTAssertEqual(result.username, draft.username)
        XCTAssertEqual(result.notes, draft.notes)
        XCTAssertEqual(result.website, draft.website)
        XCTAssertEqual(result.tags, draft.tags)
        XCTAssertTrue(result.isFavorite)
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.isDirty)
        let history = try await store.history(id)
        XCTAssertTrue(history.contains { $0.password == draft.password && $0.needsWebsiteIcon })
        // Core assigns a fresh UUID on Create. Explicit choices must suppress
        // automation for that committed UUID as well as the application draft.
        store.addItem()
        var explicit = try XCTUnwrap(store.newItemDraft)
        explicit.website = "https://icons.example/explicit"
        explicit.chooseIcon(.builtIn(0))
        let explicitlyCreated = await store.saveItem(explicit)
        XCTAssertTrue(explicitlyCreated)
        await store.waitForAutomaticIcons()
        XCTAssertEqual(store.selectedEntry?.icon, .builtIn(0))
        store.setAutomaticIconDownloads(false)
        store.setAutomaticIconDownloads(true)
        await store.waitForAutomaticIcons()
        XCTAssertEqual(store.selectedEntry?.icon, .builtIn(0), "Re-enabling must keep explicit choices in the session")
        store.lock()
        let reopened = RustVaultRepository(url: copy)
        _ = try await reopened.load(password: "fixture-password", keyFile: nil)
        defer { reopened.lock() }
        let persisted = try await reopened.entry(id)
        XCTAssertEqual(persisted.icon, result.icon)
        XCTAssertEqual(persisted.password, draft.password)
        XCTAssertEqual(persisted.website, draft.website)
    }

    func testAutomaticSaveConflictRetainsImageAndStopsQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("conflict.kdbx")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/interop.kdbx")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let icon = VaultCustomIcon(id: UUID(), name: "Synthetic", data: try image())
        let repository = IconConflictRepository(url: copy)
        let store = VaultStore(websiteIconLoader: { _ in icon })
        store.use(repository)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        store.setAutomaticIconDownloads(true)
        await store.waitForAutomaticIcons()
        XCTAssertEqual(store.operationFailure, .conflict)
        XCTAssertTrue(store.isDirty)
        XCTAssertTrue(store.customIcons.contains { $0.data == icon.data })
        XCTAssertEqual(repository.updateCount, 1)
        let external = try Data(contentsOf: copy)
        store.operationFailure = nil
        await store.waitForAutomaticIcons()
        XCTAssertEqual(repository.updateCount, 1, "Dirty state must block subsequent automatic saves")
        XCTAssertEqual(try Data(contentsOf: copy), external)
        store.lock()
    }
}

private actor IconTestTransport {
    let png: Data
    private(set) var requests: [URL] = []
    init(png: Data) { self.png = png }
    func fetch(_ url: URL, limit: Int) throws -> FaviconResponse {
        requests.append(url)
        if url.path == "/" { return FaviconResponse(data: Data("<link rel='icon' href='/site.png'>".utf8), url: url) }
        return FaviconResponse(data: png, url: url)
    }
}

private actor IconTestLoader {
    let icon: VaultCustomIcon
    private(set) var requests: [URL] = []
    init(icon: VaultCustomIcon) { self.icon = icon }
    func load(_ url: URL) throws -> VaultCustomIcon {
        requests.append(url)
        return icon
    }
}

private actor WebsiteIconTestLoader {
    let icons: [String: VaultCustomIcon]
    private(set) var requests: [URL] = []
    init(icons: [String: VaultCustomIcon]) { self.icons = icons }
    func load(_ origin: URL) throws -> VaultCustomIcon {
        requests.append(origin)
        guard let icon = icons[origin.host ?? ""] else { throw FaviconDownloader.Failure.unavailable }
        return icon
    }
}

@MainActor
private final class RefreshableIconRepository: VaultRepository {
    let capabilities = VaultCapabilities.persistent
    let requiresPassword = false
    let base: MemoryVaultRepository
    var suspendsRefresh = false
    var refreshContinuation: CheckedContinuation<Vault?, Error>?
    init(items: [VaultItem]) { base = MemoryVaultRepository(items: items) }
    func load(password: String, keyFile: URL?) async throws -> Vault { try await base.load(password: password, keyFile: keyFile) }
    func execute(_ command: VaultCommand) async throws -> VaultCommandResult { try await base.execute(command) }
    func entry(_ id: UUID) async throws -> VaultEntry { try await base.entry(id) }
    func refresh() async throws -> Vault? {
        if suspendsRefresh { return try await withCheckedThrowingContinuation { refreshContinuation = $0 } }
        return base.vault
    }
    func lock() { base.lock() }
}

private actor FailingIconLoader {
    private(set) var count = 0
    func load(_ url: URL) throws -> VaultCustomIcon {
        count += 1
        throw FaviconDownloader.Failure.unavailable
    }
}

@MainActor
private final class IconConflictRepository: VaultRepository {
    let capabilities = VaultCapabilities.persistent
    let requiresPassword = true
    let base: RustVaultRepository
    let other: RustVaultRepository
    private(set) var updateCount = 0
    init(url: URL) { base = RustVaultRepository(url: url); other = RustVaultRepository(url: url) }
    func load(password: String, keyFile: URL?) async throws -> Vault {
        _ = try await other.load(password: password, keyFile: keyFile)
        return try await base.load(password: password, keyFile: keyFile)
    }
    func entry(_ id: UUID) async throws -> VaultEntry { try await base.entry(id) }
    func execute(_ command: VaultCommand) async throws -> VaultCommandResult {
        if case .updateEntry(let entry) = command {
            updateCount += 1
            var external = try await other.entry(entry.id)
            external.notes = "Changed by a synthetic second client"
            _ = try await other.execute(.updateEntry(external))
        }
        return try await base.execute(command)
    }
    func lock() { base.lock(); other.lock() }
}

private actor IconDownloadGate {
    private var continuation: CheckedContinuation<VaultCustomIcon, Never>?
    private var icon: VaultCustomIcon?
    private var returned = false
    func load(_ icon: VaultCustomIcon) async -> VaultCustomIcon {
        self.icon = icon
        let result = await withCheckedContinuation { continuation = $0 }
        returned = true
        return result
    }
    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }
    func release() {
        continuation?.resume(returning: icon!)
        continuation = nil
    }
    func waitUntilReturned() async {
        while !returned { await Task.yield() }
    }
}
