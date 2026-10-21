import XCTest
import AppKit
@testable import KeeLocker

@MainActor
final class VaultStoreTests: XCTestCase {
    func testRecycleBinScopesRestoreAndDirectMutationGuards() async throws {
        let root = VaultGroup(id: UUID(), name: "Root", path: "Root")
        let source = VaultGroup(id: UUID(), name: "Source", parentID: root.id, path: "Root / Source")
        var entry = MockVault.items[0]
        entry.group = source
        entry.isFavorite = true
        let repository = MemoryVaultRepository(vault: Vault(name: "Synthetic", groups: [root, source], entries: [entry]))
        let store = VaultStore()
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        store.run(.deleteEntry(entry.id))
        await store.waitForOperation()
        let bin = try XCTUnwrap(store.recycleBinID)
        XCTAssertEqual(store.items.count, 1, "Trash preserves the global entry inventory")
        XCTAssertTrue(store.isInRecycleBin(id: entry.id))
        XCTAssertEqual(store.activeItemCount, 0)
        XCTAssertEqual(store.favoriteCount, 0)
        XCTAssertTrue(store.visibleItems.isEmpty)
        XCTAssertFalse(store.ordinaryGroups.contains { $0.id == bin })
        XCTAssertFalse(store.visibleGroupRows.contains { $0.id == bin })
        store.navigate(to: .favorites)
        XCTAssertTrue(store.visibleItems.isEmpty)
        store.searchQuery = entry.title
        XCTAssertTrue(store.visibleItems.isEmpty)
        store.navigate(to: .recycleBin)
        XCTAssertEqual(store.visibleItems.map(\.id), [entry.id])
        XCTAssertFalse(store.canCreateInCurrentScope)
        XCTAssertFalse(store.canEditEntry(id: entry.id))
        store.addItem()
        XCTAssertNil(store.newItemDraft)
        for command: VaultCommand in [.deleteEntry(entry.id), .updateEntry(entry), .moveEntry(entry.id, source.id),
                                      .createGroup(parent: bin, name: "Rejected"), .moveGroup(bin, source.id),
                                      .putAttachment(entry.id, "synthetic.bin", Data([1]))] {
            store.run(command)
            await store.waitForOperation()
            XCTAssertEqual(store.operationFailure, .invalidOperation)
        }
        let history = try await repository.history(entry.id)
        XCTAssertTrue(history.isEmpty, "A recoverable move must preserve the existing history without adding checkpoints")
        store.run(.restoreEntry(entry.id))
        await store.waitForOperation()
        XCTAssertFalse(store.isInRecycleBin(id: entry.id))
        XCTAssertEqual(store.items.first?.group.id, source.id)
        XCTAssertEqual(store.favoriteCount, 1)
        store.navigate(to: .allItems)
        XCTAssertEqual(store.visibleItems.map(\.id), [entry.id])
        XCTAssertTrue(store.canCreateInCurrentScope)
        store.run(.deleteEntry(entry.id))
        await store.waitForOperation()
        store.run(.deleteEntryPermanently(entry.id))
        await store.waitForOperation()
        XCTAssertTrue(store.items.isEmpty)
        store.lock()
        XCTAssertNil(store.recycleBinID)
        XCTAssertEqual(store.recycleBinCount, 0)
    }

    func testNestedTrashMembershipIgnoresInvalidRootReferenceAndAutomaticIcons() async throws {
        let root = VaultGroup(id: UUID(), name: "Root", path: "Root")
        let bin = VaultGroup(id: UUID(), name: "Bin", parentID: root.id, path: "Root / Bin")
        let nested = VaultGroup(id: UUID(), name: "Nested", parentID: bin.id, path: "Root / Bin / Nested")
        var entry = MockVault.items[0]
        entry.group = nested
        entry.icon = .builtIn(0)
        entry.isFavorite = true
        entry.website = "https://synthetic.invalid"
        for reference in [root.id, UUID(), bin.id] {
            let repository = MemoryVaultRepository(vault: Vault(name: "Synthetic", groups: [root, bin, nested], entries: [entry], recycleBinID: reference))
            let store = VaultStore(websiteIconLoader: { _ in
                XCTFail("Entries in the recycle subtree must not trigger icon downloads")
                throw VaultFailure.invalidOperation
            })
            store.use(repository)
            store.unlock()
            await store.waitForUnlock()
            XCTAssertEqual(store.isInRecycleBin(id: entry.id), reference == bin.id)
            if reference == bin.id {
                XCTAssertEqual(store.ordinaryGroups.map(\.id), [root.id])
                store.navigate(to: .recycleBin)
                XCTAssertEqual(store.visibleItems.map(\.id), [entry.id])
                store.setAutomaticIconDownloads(true)
                await store.waitForAutomaticIcons()
                store.setAutomaticIconDownloads(false)
                store.run(.restoreEntry(entry.id))
                await store.waitForOperation()
                XCTAssertEqual(store.items.first?.group.id, root.id)
            } else {
                XCTAssertEqual(store.activeItemCount, 1)
            }
            store.lock()
        }
    }

    func testDisabledRecycleBinDeletesPermanentlyInMemoryRepository() async throws {
        let root = VaultGroup(id: UUID(), name: "Synthetic", path: "Synthetic")
        var entry = MockVault.items[0]
        entry.group = root
        let repository = MemoryVaultRepository(vault: Vault(name: "Synthetic", groups: [root], entries: [entry], recycleBinEnabled: false))
        let store = VaultStore()
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        XCTAssertFalse(store.recycleBinEnabled)
        store.run(.deleteEntry(entry.id))
        await store.waitForOperation()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.recycleBinID)
    }

    func testTrashAutosaveConflictRetainsMutationAndSavesCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("synthetic.kdbx")
        let copy = directory.appendingPathComponent("recovered.kdbx")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/interop.kdbx")
        try FileManager.default.copyItem(at: fixture, to: source)
        let repository = RustVaultRepository(url: source)
        let initial = try await repository.load(password: "fixture-password", keyFile: nil)
        defer { repository.lock() }
        let id = try XCTUnwrap(initial.entries.first?.id)
        let original = try Data(contentsOf: source)
        var changed = original
        changed.append(0)
        try changed.write(to: source)
        let deleted = try await repository.execute(.deleteEntry(id))
        XCTAssertEqual(deleted.saveFailure, .conflict)
        XCTAssertTrue(deleted.vault.isDirty)
        let retained = try XCTUnwrap(deleted.vault.entries.first { $0.id == id })
        XCTAssertEqual(retained.group.id, deleted.vault.recycleBinID)
        XCTAssertEqual(try Data(contentsOf: source), changed)
        let saved = try await repository.execute(.saveAs(copy))
        XCTAssertNil(saved.saveFailure)
        let reopened = RustVaultRepository(url: copy)
        defer { reopened.lock() }
        let current = try await reopened.load(password: "fixture-password", keyFile: nil)
        XCTAssertEqual(current.entries.first { $0.id == id }?.group.id, current.recycleBinID)
    }

    func testLargeCustomIconCatalogMapsWithoutQuadraticLookup() async throws {
        let groupID = UUID().uuidString
        let icons = (0..<4_000).map { CoreCustomIcon(id: UUID().uuidString, name: "Synthetic \($0)", data: Data([1])) }
        let entries = icons.map { icon in
            CoreEntry(id: UUID().uuidString, groupId: groupID, title: "Synthetic", username: "", password: "",
                      url: "", notes: "", tags: [], customFields: [], attachments: [], historyCount: 0,
                      createdAt: nil, modifiedAt: nil, otp: nil, icon: .custom(id: icon.id),
                      websiteIconOrigin: nil, hasExplicitIcon: false)
        }
        let group = CoreGroup(id: groupID, parentId: nil, name: "Synthetic", path: "Synthetic", createdAt: nil, modifiedAt: nil)
        let source = CoreSnapshot(info: CoreVaultInfo(name: "Synthetic scale", path: "/tmp/synthetic-scale.kdbx", dirty: false, rootId: groupID, recycleBinId: nil, recycleBinEnabled: true),
                                  groups: [group], entries: entries, customIcons: icons)
        let repository = RustVaultRepository(url: URL(fileURLWithPath: source.info.path), opening: SnapshotVaultOpening(source: source))
        defer { repository.lock() }
        let start = ContinuousClock.now
        let result = try await repository.load(password: "synthetic", keyFile: nil)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertEqual(result.entries.count, 4_000)
        if case .custom(let last) = result.entries.last?.icon {
            XCTAssertEqual(last.id.uuidString, icons.last?.id)
        } else { XCTFail("The complete custom icon catalog must be mapped") }
    }

    func testDetailAndHistoryReadUseCatalogFromTheirOwnRevision() async throws {
        for readsHistory in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let copy = directory.appendingPathComponent("catalog-race.kdbx")
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/interop.kdbx")
            try FileManager.default.copyItem(at: fixture, to: copy)
            let gate = SynchronousLoadGate()
            defer { gate.release() }
            let repository = RustVaultRepository(url: copy, opening: CatalogRaceOpening(gate: gate, readsHistory: readsHistory))
            let initial = try await repository.load(password: "fixture-password", keyFile: nil)
            defer { repository.lock() }
            let id = try XCTUnwrap(initial.entries.first?.id)
            let reading = Task {
                if readsHistory { return try await repository.history(id) }
                return [try await repository.entry(id)]
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !gate.entered, ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertTrue(gate.entered)
            guard gate.entered else { throw CancellationError() }
            let external = RustVaultRepository(url: copy)
            _ = try await external.load(password: "fixture-password", keyFile: nil)
            defer { external.lock() }
            var changed = try await external.entry(id)
            let icon = try IconImageImport.normalized(syntheticIconPNG(), name: "Synthetic new revision")
            changed.chooseIcon(.imported(icon))
            _ = try await external.execute(.updateEntry(changed))
            changed = try await external.entry(id)
            changed.notes = "Another synthetic edit retains the custom icon in history"
            _ = try await external.execute(.updateEntry(changed))
            let refreshed = try await repository.refresh()
            XCTAssertNotNil(refreshed)
            gate.release()
            let result = try await reading.value
            XCTAssertTrue(result.contains { $0.icon?.imageData == icon.data })
        }
    }

    func testIconImportDiscardsLateResultsAfterCancelAndReplacement() async throws {
        let gate = SynchronousLoadGate()
        defer { gate.release() }
        let started = expectation(description: "Image reading started")
        started.expectedFulfillmentCount = 2
        let icon = VaultCustomIcon(id: UUID(), name: "Synthetic", data: Data([1, 2, 3]))
        let imports = IconImportSession(loader: { _ in
            await Task.detached {
                started.fulfill()
                gate.wait()
                return icon
            }.value
        })
        let url = URL(fileURLWithPath: "/tmp/synthetic-icon.png")
        let oldRequest = imports.begin()
        let oldRead = Task { try await imports.load(url, request: oldRequest) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !gate.entered, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(gate.entered)
        imports.invalidate()
        let obsoletePickerResult = try await imports.load(url, request: oldRequest)
        XCTAssertNil(obsoletePickerResult)
        let newRequest = imports.begin()
        let newRead = Task { try await imports.load(url, request: newRequest) }
        await fulfillment(of: [started], timeout: 3)
        gate.release()
        let obsoleteRead = try await oldRead.value
        let currentRead = try await newRead.value
        XCTAssertNil(obsoleteRead, "Invalidation must discard a read even without cancelling its task")
        XCTAssertEqual(currentRead, icon)
    }

    func testIconImportDiscardsLateFailuresFromClosedEditor() async throws {
        let gate = SynchronousLoadGate()
        defer { gate.release() }
        let started = expectation(description: "Image reading started")
        let imports = IconImportSession(loader: { _ in
            try await Task.detached {
                started.fulfill()
                gate.wait()
                throw IconImageImport.Failure.invalidImage
            }.value
        })
        let request = imports.begin()
        let read = Task { try await imports.load(URL(fileURLWithPath: "/tmp/synthetic-icon.png"), request: request) }
        await fulfillment(of: [started], timeout: 3)
        imports.invalidate()
        gate.release()
        let result = try await read.value
        XCTAssertNil(result, "A closed editor must not present an obsolete import failure")
    }

    func testStandardIconCatalogHasEveryKeePassIDAndAvailableSymbols() {
        XCTAssertEqual(StandardVaultIcon.all.map(\.id), Array(UInt64(0)...UInt64(68)))
        for icon in StandardVaultIcon.all {
            XCTAssertNotNil(NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil), icon.name)
        }
    }

    private func syntheticIconPNG() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 180,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<180 {
            for x in 0..<300 {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = 217
                pixels[offset + 1] = 51
                pixels[offset + 2] = 128
                pixels[offset + 3] = 255
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testIconImportNormalizesImageAndRejectsInvalidInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Synthetic.png")
        let source = try syntheticIconPNG()
        try source.write(to: url)
        let imported = try await Task.detached { try IconImageImport.load(url) }.value
        XCTAssertEqual(imported.name, "Synthetic")
        let image = try XCTUnwrap(IconImageImport.preview(imported.data))
        XCTAssertEqual(image.width, 128)
        XCTAssertEqual(image.height, 77)
        let pixel = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        let original = try XCTUnwrap(NSBitmapImageRep(data: source)?.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        XCTAssertEqual(pixel.alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(pixel.redComponent, original.redComponent, accuracy: 0.02)
        XCTAssertLessThan(imported.data.count, 1024 * 1024)
        try Data("Invalid image".utf8).write(to: url)
        do {
            _ = try await Task.detached { try IconImageImport.load(url) }.value
            XCTFail("Invalid images must not enter the draft")
        } catch { XCTAssertTrue(error is IconImageImport.Failure) }
        XCTAssertNil(IconImageImport.preview(Data()))
    }

    func testDemoIconDraftCancelSaveAndLock() async throws {
        let repository = MemoryVaultRepository()
        let store = VaultStore()
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        let entries = repository.vault.entries
        let icon = VaultCustomIcon(id: UUID(), name: "Synthetic", data: try syntheticIconPNG())
        store.addItem()
        var draft = try XCTUnwrap(store.newItemDraft)
        draft.chooseIcon(.imported(icon))
        XCTAssertTrue(repository.vault.customIcons.isEmpty)
        store.cancelNewItem()
        XCTAssertEqual(repository.vault.entries, entries)
        XCTAssertTrue(repository.vault.customIcons.isEmpty)
        store.addItem()
        draft = try XCTUnwrap(store.newItemDraft)
        draft.title = "Synthetic icon draft"
        draft.chooseIcon(.imported(icon))
        let saved = await store.saveItem(draft)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.customIcons, [icon])
        XCTAssertEqual(store.selectedEntry?.icon, .custom(icon))
        XCTAssertEqual(store.selectedEntry?.isIconModified, false)
        var edit = try XCTUnwrap(store.selectedEntry)
        edit.chooseIcon(.builtIn(19))
        let edited = await store.saveItem(edit)
        XCTAssertTrue(edited)
        XCTAssertEqual(store.selectedEntry?.icon, .builtIn(19))
        store.lock()
        XCTAssertTrue(store.customIcons.isEmpty)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testRealVaultIconsSaveReopenAndRetainHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("synthetic.kdbx")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/interop.kdbx")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let png = directory.appendingPathComponent("Synthetic.png")
        try syntheticIconPNG().write(to: png)
        let icon = try await Task.detached { try IconImageImport.load(png) }.value
        let store = VaultStore()
        store.openFile(copy)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        store.addItem()
        var draft = try XCTUnwrap(store.newItemDraft)
        draft.title = "Synthetic icon entry"
        draft.chooseIcon(.builtIn(19))
        let created = await store.saveItem(draft)
        XCTAssertTrue(created)
        var entry = try XCTUnwrap(store.selectedEntry)
        let id = entry.id
        XCTAssertEqual(entry.icon, .builtIn(19))
        entry.chooseIcon(.imported(icon))
        let imported = await store.saveItem(entry)
        XCTAssertTrue(imported)
        let stored = try XCTUnwrap(store.customIcons.first { $0.data == icon.data })
        XCTAssertEqual(store.selectedEntry?.icon, .custom(stored))
        let history = try await store.history(id)
        XCTAssertEqual(history.first?.icon, .builtIn(19))
        store.addItem()
        var shared = try XCTUnwrap(store.newItemDraft)
        shared.title = "Shared custom icon"
        shared.chooseIcon(.custom(stored))
        let reused = await store.saveItem(shared)
        XCTAssertTrue(reused)
        XCTAssertEqual(store.selectedEntry?.icon, .custom(stored))
        XCTAssertEqual(store.customIcons.filter { $0.data == stored.data }.count, 1)
        store.selectedItemID = id
        await store.waitForSelection()
        // Unrelated edits must preserve the custom UUID and bytes.
        entry = try XCTUnwrap(store.selectedEntry)
        entry.notes = "Ordinary field edit"
        let edited = await store.saveItem(entry)
        XCTAssertTrue(edited)
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.isDirty)
        store.lock()
        XCTAssertTrue(store.customIcons.isEmpty)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        store.selectedItemID = id
        await store.waitForSelection()
        XCTAssertEqual(store.selectedEntry?.icon, .custom(stored))
        XCTAssertTrue(store.customIcons.contains(stored))
        store.lock()
    }

    func testCappedHistoryInvalidatesInspectionWhenCountAndTimestampStayTheSame() async throws {
        let repository = CappedHistoryRepository()
        let store = VaultStore()
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        let id = repository.vault.entries[0].id
        store.inspectedEntryID = id
        let original = try await store.history(id)
        let revision = store.snapshotRevision
        XCTAssertEqual(original.map(\.title), ["Synthetic v0"])
        store.run(.putAttachment(id, "synthetic.bin", Data([1, 2, 3])))
        await store.waitForOperation()
        let replacement = try await store.history(id)
        XCTAssertEqual(store.items.first?.historyCount, 1)
        XCTAssertEqual(replacement.count, original.count)
        XCTAssertEqual(replacement.first?.modifiedAt, original.first?.modifiedAt)
        XCTAssertEqual(replacement.map(\.title), ["Synthetic v1"])
        XCTAssertNotEqual(store.snapshotRevision, revision,
                          "An open history sheet must reload when a capped version is replaced")
        store.lock()
    }

    func testSupersededPasswordLoadReturnsToLockedWithoutAFileError() async throws {
        let repository = SuspendedRepository()
        let store = VaultStore()
        store.use(repository)
        store.unlock(password: "synthetic-password")
        while repository.continuation == nil { await Task.yield() }
        repository.continuation?.resume(throwing: CancellationError())
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .locked)
        XCTAssertNil(store.failure)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testInitialRefreshKeepsEditingBlockedUntilUnchangedSelectedDetailsAreReady() async throws {
        let repository = InitialSelectionRepository()
        let store = VaultStore()
        store.use(repository, fileURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).kdbx"))
        store.unlock()
        while repository.selection == nil || repository.refreshes == 0 { await Task.yield() }
        XCTAssertTrue(store.isBusy, "An unchanged refresh must still wait for initial selected details")
        store.run(.save)
        XCTAssertEqual(repository.commands, 0)
        repository.selection?.resume(returning: repository.entry)
        await store.waitForUnlock()
        await store.waitForOperation()
        XCTAssertEqual(repository.commands, 0)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.selectedEntry?.id, store.selectedItemID)
        store.lock()
    }

    func testDelayedCommandCannotMutateAReplacementSession() async throws {
        let store = VaultStore(items: MockVault.items)
        let request = store.sessionID
        let id = try XCTUnwrap(store.items.first?.id)
        let replacement = MemoryVaultRepository()
        store.use(replacement)
        store.unlock()
        await store.waitForUnlock()
        let before = replacement.vault.entries
        store.run(.deleteEntry(id), session: request)
        await store.waitForOperation()
        XCTAssertEqual(replacement.vault.entries, before)
    }
    func testCreationStaysBusyUntilDraftHasBeenConsumed() async throws {
        let repository = SuspendedSelectionRepository()
        repository.suspendAfterCreation = true
        let store = VaultStore()
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        store.addItem()
        let draft = try XCTUnwrap(store.newItemDraft)
        let saving = Task { await store.saveItem(draft) }
        while repository.continuation == nil { await Task.yield() }
        XCTAssertTrue(store.isBusy, "Save must not be enabled again for an already-created draft")
        repository.completeSelection(.success(try XCTUnwrap(repository.suspendedEntry)))
        let saved = await saving.value
        XCTAssertTrue(saved)
        XCTAssertNil(store.newItemDraft)
        XCTAssertFalse(store.hasDraft)
        XCTAssertFalse(store.isBusy)
    }

    func testFailedDetailRefreshClearsStaleEditableSelection() async throws {
        let repository = SuspendedSelectionRepository()
        let store = VaultStore()
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        XCTAssertNotNil(store.selectedEntry)
        store.refreshFromDisk()
        while repository.continuation == nil { await Task.yield() }
        repository.completeSelection(.failure(VaultFailure.failedToReadFile))
        await store.waitForRefresh()
        XCTAssertNil(store.selectedEntry)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.operationFailure, .failedToReadFile)
    }

    func testExternalRefreshKeepsEditingBlockedUntilSelectedDetailsAreCurrent() async throws {
        let repository = SuspendedSelectionRepository()
        let store = VaultStore()
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        let previous = try XCTUnwrap(store.selectedEntry)
        store.refreshFromDisk()
        while repository.continuation == nil { await Task.yield() }
        XCTAssertTrue(store.isBusy, "Editing must stay blocked while selected details still contain the old file contents")
        XCTAssertEqual(store.selectedEntry?.username, previous.username)
        repository.completeSelection(.success(repository.currentEntry))
        await store.waitForRefresh()
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.selectedEntry?.username, "Externally refreshed username")
    }

    func testNewItemStartsAsDraftWithoutChangingGroupOrRepository() async throws {
        let repository = MemoryVaultRepository()
        let store = VaultStore()
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        let group = try XCTUnwrap(store.groups.first { $0.id == VaultGroup.work.id })
        store.navigate(to: .group(group))
        let originalItems = store.items
        let originalVisibleItems = store.visibleItems

        store.addItem()
        await store.waitForOperation()

        XCTAssertEqual(store.sidebarSelection, .group(group))
        XCTAssertTrue(store.hasDraft)
        XCTAssertEqual(store.items, originalItems)
        XCTAssertEqual(store.visibleItems, originalVisibleItems)
        XCTAssertEqual(repository.vault.entries, originalItems)
        XCTAssertFalse(store.isDirty)
        XCTAssertNil(store.selectedEntry)
        var draft = try XCTUnwrap(store.newItemDraft)
        store.addItem()
        XCTAssertEqual(store.newItemDraft?.id, draft.id)
        draft.title = "Created only on Save"
        draft.username = "draft-user"
        draft.password = "synthetic-draft-password"
        let saved = await store.saveItem(draft)
        XCTAssertTrue(saved)
        XCTAssertFalse(store.hasDraft)
        XCTAssertNil(store.newItemDraft)
        XCTAssertEqual(store.sidebarSelection, .group(group))
        XCTAssertEqual(store.items.count, originalItems.count + 1)
        XCTAssertEqual(repository.vault.entries.count, originalItems.count + 1)
        XCTAssertEqual(store.selectedEntry?.title, draft.title)
        XCTAssertEqual(store.selectedEntry?.password, draft.password)
        XCTAssertEqual(store.selectedEntry?.group.id, group.id)
    }

    func testCancelNewItemRestoresSelectionAndFavoritesCreateWithoutLeavingScope() async throws {
        let store = VaultStore(items: MockVault.items)
        store.navigate(to: .favorites)
        await store.waitForSelection()
        let previous = store.selectedItemID
        let count = store.items.count
        store.addItem()
        XCTAssertTrue(store.hasDraft)
        XCTAssertEqual(store.newItemDraft?.isFavorite, true)
        store.cancelNewItem()
        await store.waitForSelection()
        XCTAssertFalse(store.hasDraft)
        XCTAssertNil(store.newItemDraft)
        XCTAssertEqual(store.selectedItemID, previous)
        XCTAssertEqual(store.items.count, count)
        XCTAssertEqual(store.sidebarSelection, .favorites)
        store.addItem()
        let draft = try XCTUnwrap(store.newItemDraft)
        let saved = await store.saveItem(draft)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.sidebarSelection, .favorites)
        XCTAssertEqual(store.selectedItemID, draft.id)
        XCTAssertTrue(store.visibleItems.contains { $0.id == draft.id && $0.isFavorite })
        store.addItem()
        store.lock()
        XCTAssertNil(store.newItemDraft)
        XCTAssertFalse(store.hasDraft)
    }

    func testFailedNewItemCreationKeepsDraftAndRetryCreatesOnce() async throws {
        let repository = RejectFirstCreationRepository()
        let store = VaultStore()
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        let count = store.items.count
        store.addItem()
        var draft = try XCTUnwrap(store.newItemDraft)
        draft.title = "Retry draft"
        draft.password = "synthetic-retry-password"
        let rejected = await store.saveItem(draft)
        XCTAssertFalse(rejected)
        XCTAssertTrue(store.hasDraft)
        XCTAssertEqual(store.newItemDraft?.id, draft.id)
        XCTAssertEqual(store.items.count, count)
        XCTAssertEqual(store.operationFailure, .invalidOperation)
        let saved = await store.saveItem(draft)
        XCTAssertTrue(saved)
        XCTAssertFalse(store.hasDraft)
        XCTAssertNil(store.newItemDraft)
        XCTAssertEqual(store.items.count, count + 1)
        XCTAssertEqual(store.selectedEntry?.password, draft.password)
        XCTAssertNil(store.operationFailure)
    }

    func testGroupTreeUsesParentIDsAndKeepsCollapsedBranchesSeparate() {
        let root = VaultGroup(id: UUID(), name: "Root", path: "Root")
        let child = VaultGroup(id: UUID(), name: "Shared", parentID: root.id, path: "Root / Shared")
        let leaf = VaultGroup(id: UUID(), name: "Leaf / literal slash", parentID: child.id, path: "Root / Shared / Leaf / literal slash")
        let sibling = VaultGroup(id: UUID(), name: "Shared", parentID: root.id, path: "Root / Shared")
        let secondRoot = VaultGroup(id: UUID(), name: "Other", path: "Other")
        // The repository's array order does not need to be a depth-first traversal.
        let groups = [leaf, root, child, secondRoot, sibling]
        let expanded = VaultGroupTree.rows(groups, collapsed: [])
        XCTAssertEqual(expanded.map(\.id), [root.id, child.id, leaf.id, sibling.id, secondRoot.id])
        XCTAssertEqual(expanded.map(\.depth), [0, 1, 2, 1, 0])
        XCTAssertEqual(expanded.map(\.hasChildren), [true, true, false, false, false])
        XCTAssertEqual(expanded[2].group.name, "Leaf / literal slash")
        XCTAssertEqual(VaultGroupTree.rows(groups, collapsed: [child.id]).map(\.id),
                       [root.id, child.id, sibling.id, secondRoot.id])
        XCTAssertEqual(VaultGroupTree.rows(groups, collapsed: [root.id]).map(\.id), [root.id, secondRoot.id])
    }

    func testGroupCollapseKeepsSelectionVisibleAndNewChildExpandsItsParent() async throws {
        let store = VaultStore(items: MockVault.items)
        let root = try XCTUnwrap(store.rootGroupCreationParent)
        store.run(.createGroup(parent: root.id, name: "Child"))
        await store.waitForOperation()
        let child = try XCTUnwrap(store.groups.first { $0.parentID == root.id })
        store.run(.createGroup(parent: child.id, name: "Grandchild"))
        await store.waitForOperation()
        let leaf = try XCTUnwrap(store.groups.first { $0.parentID == child.id })
        XCTAssertEqual(store.sidebarSelection, .group(leaf))
        XCTAssertEqual(store.groupCreationParent?.id, leaf.id)
        XCTAssertEqual(store.rootGroupCreationParent?.id, root.id)

        store.toggleGroupExpansion(root.id)
        XCTAssertEqual(store.sidebarSelection, .group(root))
        XCTAssertFalse(store.visibleGroupRows.contains { $0.id == child.id })
        store.navigate(to: .group(leaf))
        XCTAssertTrue(store.visibleGroupRows.contains { $0.id == leaf.id })
        store.navigate(to: .allItems)
        store.toggleGroupExpansion(root.id)
        XCTAssertTrue(store.collapsedGroupIDs.contains(root.id))
        store.run(.createGroup(parent: root.id, name: "Created in collapsed root"))
        await store.waitForOperation()
        let created = try XCTUnwrap(store.groups.first { $0.name == "Created in collapsed root" })
        XCTAssertEqual(store.sidebarSelection, .group(created))
        XCTAssertFalse(store.collapsedGroupIDs.contains(root.id))
        XCTAssertTrue(store.visibleGroupRows.contains { $0.id == created.id })
        store.lock()
        XCTAssertTrue(store.visibleGroupRows.isEmpty)
        XCTAssertTrue(store.collapsedGroupIDs.isEmpty)
        XCTAssertNil(store.rootGroupCreationParent)
    }

    func testLastSelectedFileRestoresLockedAndSurvivesDemoAndLock() async throws {
        let suite = "KeeLockerTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = VaultStore(preferences: preferences)
        XCTAssertEqual(store.state, .noVault)

        let first = URL(fileURLWithPath: "/tmp/First vault.kdbx")
        let latest = URL(fileURLWithPath: "/tmp/Последняя база.kdbx")
        store.openFile(first)
        store.openFile(latest)
        store.lock()
        store.openDemo()
        await store.waitForUnlock()

        let relaunched = VaultStore(preferences: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(relaunched.fileURL, latest)
        XCTAssertEqual(relaunched.state, .locked)
        XCTAssertTrue(relaunched.requiresPassword)
        XCTAssertTrue(relaunched.items.isEmpty)
        XCTAssertTrue(relaunched.groups.isEmpty)
        XCTAssertNil(relaunched.selectedEntry)
        XCTAssertEqual(preferences.persistentDomain(forName: suite)?.keys.sorted(), ["lastVaultPath"])
    }

    func testSearchIgnoresSurroundingWhitespace() {
        let store = VaultStore(items: MockVault.items)

        store.searchQuery = "  github  "

        XCTAssertEqual(store.visibleItems.map(\.title), ["GitHub"])
    }

    func testBusyRefreshRefusesSaveAndLateResultCannotRestoreOldVault() async throws {
        let repository = SuspendedRefreshRepository()
        let store = VaultStore()
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        let entry = try XCTUnwrap(store.selectedEntry)
        store.refreshFromDisk()
        while repository.continuation == nil { await Task.yield() }
        let saved = await store.saveItem(entry)
        XCTAssertFalse(saved)
        XCTAssertEqual(repository.commandCount, 0)
        store.lock()
        store.openDemo()
        await store.waitForUnlock()
        repository.continuation?.resume(returning: Vault(name: "Stale refreshed vault", groups: [], entries: []))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.vaultName, "Personal Vault")
        XCTAssertEqual(store.items.count, 9)
        XCTAssertEqual(store.state, .unlocked)
        XCTAssertFalse(store.isBusy)
    }

    func testLockedVaultRefusesNewItems() {
        let store = VaultStore(items: MockVault.items)
        store.lock()
        store.addItem()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.selectedItemID)
        XCTAssertEqual(store.state, .locked)
    }

    func testReconcileSelectionDropsItemRemovedFromFavorites() async {
        let store = VaultStore(items: MockVault.items)
        guard let selectedID = store.items.first(where: \.isFavorite)?.id else {
            return XCTFail("Mock vault must contain a favorite item")
        }
        store.sidebarSelection = .favorites
        store.selectedItemID = selectedID

        guard let index = store.items.firstIndex(where: { $0.id == selectedID }) else {
            return XCTFail("Selected favorite must exist in the store")
        }
        var updatedItem = store.items[index]
        updatedItem.isFavorite = false
        store.updateItem(updatedItem)
        await store.waitForOperation()

        XCTAssertNotEqual(store.selectedItemID, selectedID)
        XCTAssertTrue(store.selectedItemID.map { id in
            store.visibleItems.contains(where: { $0.id == id })
        } ?? store.visibleItems.isEmpty)
    }
}

final class VaultItemValidationTests: XCTestCase {
    func testWebsiteURLAcceptsOnlyHTTPURLsWithHost() {
        var item = MockVault.items[0]

        item.website = "https://example.com/account"
        XCTAssertEqual(item.websiteURL?.absoluteString, "https://example.com/account")

        item.website = "https://"
        XCTAssertNil(item.websiteURL)

        item.website = "file:///tmp/example"
        XCTAssertNil(item.websiteURL)
    }

    func testOneTimePasswordPeriodIsNeverBelowOne() {
        XCTAssertEqual(OneTimePassword(code: "123 456", period: 0).safePeriod, 1)
        XCTAssertEqual(OneTimePassword(code: "123 456", period: 30).safePeriod, 30)
    }
}

@MainActor
final class KdbxIntegrationTests: XCTestCase {
    func testConfiguredBackupsSurvivePasswordAndCachedKeySavesWithoutCleanSaveChurn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("synthetic.kdbx")
        let backups = directory.appendingPathComponent("private-backups")
        try FileManager.default.copyItem(at: fixture(), to: copy)
        let original = try Data(contentsOf: copy)
        let repository = RustVaultRepository(url: copy, backupDirectory: backups)
        let initial = try await repository.load(password: "fixture-password", keyFile: nil)
        let material = try await repository.keyMaterial()
        let id = try XCTUnwrap(initial.entries.first?.id)
        let deleted = try await repository.execute(.deleteEntry(id))
        XCTAssertNil(deleted.saveFailure)
        XCTAssertFalse(deleted.vault.isDirty)
        let written = try Data(contentsOf: copy)
        let previous = try Data(contentsOf: URL(fileURLWithPath: copy.path + ".bak"))
        _ = try await repository.execute(.save)
        XCTAssertEqual(try Data(contentsOf: copy), written)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copy.path + ".bak")), previous)
        repository.lock()

        let reopened = RustVaultRepository(url: copy, backupDirectory: backups)
        defer { reopened.lock() }
        let current = try await reopened.load(keyMaterial: material)
        let remainingID = try XCTUnwrap(current.entries.first { !current.recycledGroupIDs.contains($0.group.id) }?.id)
        var entry = try await reopened.entry(remainingID)
        entry.notes += "\nSynthetic cached-key save"
        let saved = try await reopened.execute(.updateEntry(entry))
        XCTAssertNil(saved.saveFailure)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: backups, includingPropertiesForKeys: nil))
        let pinned = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "original.kdbx" }
        XCTAssertEqual(pinned.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(pinned.first)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".keelocker-backups").path))
    }

    func testUnavailableBackupDirectoryRetainsStoreEditsAndAllowsSaveCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("synthetic.kdbx")
        let backups = directory.appendingPathComponent("blocked-backups")
        let rescue = directory.appendingPathComponent("rescued.kdbx")
        try FileManager.default.copyItem(at: fixture(), to: copy)
        let original = try Data(contentsOf: copy)
        let store = VaultStore(backupDirectory: backups)
        store.openFile(copy)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        defer { store.lock() }
        try Data("Synthetic file blocks the backup directory".utf8).write(to: backups)
        var entry = try XCTUnwrap(store.selectedEntry)
        entry.notes = "Synthetic unsaved edit survives backup failure"
        store.updateItem(entry)
        await store.waitForOperation()
        XCTAssertEqual(store.operationFailure, .writeFailed)
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.selectedEntry?.notes, entry.notes)
        XCTAssertEqual(try Data(contentsOf: copy), original)
        store.run(.saveAs(rescue))
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.isDirty)
        let recovered = RustVaultRepository(url: rescue)
        _ = try await recovered.load(password: "fixture-password", keyFile: nil)
        defer { recovered.lock() }
        let recoveredEntry = try await recovered.entry(entry.id)
        XCTAssertEqual(recoveredEntry.notes, entry.notes)
    }

    func testRedactedSummariesCannotOverwriteSecrets() async throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kdbx")
        try FileManager.default.copyItem(at: fixture(), to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(atPath: copy.path + ".bak")
        }
        let repository = RustVaultRepository(url: copy)
        let vault = try await repository.load(password: "fixture-password", keyFile: nil)
        defer { repository.lock() }
        var summary = try XCTUnwrap(vault.entries.first { $0.title == "GitHub тест 🔐" })
        let before = try await repository.entry(summary.id)
        summary.title = "Summary edit"
        do {
            _ = try await repository.execute(.updateEntry(summary))
            XCTFail("Redacted summary must not be used for a replacement edit")
        } catch { XCTAssertEqual(error as? VaultFailure, .invalidOperation) }
        let after = try await repository.entry(summary.id)
        XCTAssertEqual(after.password, before.password)
        XCTAssertEqual(after.customFields.first { $0.name == "Recovery code" }?.value, "recovery-secret")
        XCTAssertEqual(after.title, before.title)
    }
    func testNewItemCancelLeavesFileUntouchedAndSaveCreatesInSelectedGroup() async throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kdbx")
        try FileManager.default.copyItem(at: fixture(), to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(atPath: copy.path + ".bak")
        }
        let store = VaultStore()
        store.openFile(copy)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        defer { store.lock() }
        let group = try XCTUnwrap(store.groups.first { $0.name == "Empty" })
        store.navigate(to: .group(group))
        let bytes = try Data(contentsOf: copy)
        let count = store.items.count
        store.addItem()
        await store.waitForOperation()
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path + ".bak"))
        store.cancelNewItem()
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertEqual(store.items.count, count)
        XCTAssertEqual(store.sidebarSelection, .group(group))

        store.addItem()
        var draft = try XCTUnwrap(store.newItemDraft)
        draft.title = "Saved new draft"
        draft.username = "fixture-draft-user"
        draft.password = "fixture-draft-secret"
        draft.website = "https://example.test/draft"
        draft.notes = "Draft notes"
        draft.tags = ["draft-tag"]
        draft.customFields = [CustomField(name: "Secret", value: "synthetic-secret", isSensitive: true)]
        let saved = await store.saveItem(draft)
        XCTAssertTrue(saved)
        XCTAssertFalse(store.hasDraft)
        XCTAssertFalse(store.isDirty)
        XCTAssertNil(store.operationFailure)
        XCTAssertEqual(store.sidebarSelection, .group(group))
        let created = try XCTUnwrap(store.selectedEntry)
        XCTAssertEqual(created.title, draft.title)
        XCTAssertEqual(created.group.id, group.id)
        XCTAssertEqual(store.visibleItems.map(\.id), [created.id])
        let reopened = RustVaultRepository(url: copy)
        let vault = try await reopened.load(password: "fixture-password", keyFile: nil)
        defer { reopened.lock() }
        XCTAssertEqual(vault.entries.count, count + 1)
        XCTAssertEqual(vault.entries.filter { $0.title == draft.title }.count, 1)
        let entry = try await reopened.entry(created.id)
        XCTAssertEqual(entry.group.id, group.id)
        XCTAssertEqual(entry.username, draft.username)
        XCTAssertEqual(entry.password, draft.password)
        XCTAssertEqual(entry.website, draft.website)
        XCTAssertEqual(entry.notes, draft.notes)
        XCTAssertEqual(entry.tags, draft.tags)
        XCTAssertEqual(entry.customFields.first?.value, "synthetic-secret")
    }

    func testExternalAtomicSaveRefreshesOpenVaultAndAllowsFurtherEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("shared.kdbx")
        try FileManager.default.copyItem(at: fixture(), to: copy)
        let store = VaultStore()
        store.openFile(copy)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        defer { store.lock() }
        let selected = try XCTUnwrap(store.selectedEntry)
        store.searchQuery = selected.username

        let other = RustVaultRepository(url: copy)
        _ = try await other.load(password: "fixture-password", keyFile: nil)
        defer { other.lock() }
        var external = try await other.entry(selected.id)
        external.title = "Saved by another application"
        external.notes = "External notes"
        _ = try await other.execute(.updateEntry(external))

        let deadline = Date().addingTimeInterval(3)
        while store.selectedEntry?.title != external.title && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(store.items.first { $0.id == selected.id }?.title, external.title)
        XCTAssertEqual(store.selectedEntry?.notes, external.notes)
        XCTAssertEqual(store.selectedItemID, selected.id)
        XCTAssertEqual(store.searchQuery, selected.username)
        XCTAssertNil(store.operationFailure)

        var local = try XCTUnwrap(store.selectedEntry)
        local.title = "Saved in KeeLocker after external change"
        store.updateItem(local)
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.isDirty)
        let reopened = RustVaultRepository(url: copy)
        _ = try await reopened.load(password: "fixture-password", keyFile: nil)
        defer { reopened.lock() }
        let result = try await reopened.entry(selected.id)
        XCTAssertEqual(result.title, local.title)
        XCTAssertEqual(result.notes, external.notes)
    }

    func testExternalSaveDuringDraftIsDeferredAndConflictCanReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("shared.kdbx")
        try FileManager.default.copyItem(at: fixture(), to: copy)
        let store = VaultStore()
        store.openFile(copy)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        defer { store.lock() }
        var local = try XCTUnwrap(store.selectedEntry)
        let originalTitle = local.title
        let editorGeneration = store.editorGeneration
        store.hasDraft = true
        let other = RustVaultRepository(url: copy)
        _ = try await other.load(password: "fixture-password", keyFile: nil)
        defer { other.lock() }
        var external = try await other.entry(local.id)
        external.title = "Externally changed during editing"
        _ = try await other.execute(.updateEntry(external))
        let externalBytes = try Data(contentsOf: copy)
        store.refreshFromDisk()
        await store.waitForRefresh()
        XCTAssertTrue(store.hasDraft)
        XCTAssertEqual(store.selectedEntry?.title, originalTitle)
        local.title = "My unsaved edit"
        store.updateItem(local)
        await store.waitForOperation()
        store.hasDraft = false
        await store.waitForRefresh()
        XCTAssertEqual(store.operationFailure, .conflict)
        XCTAssertTrue(store.lastCommandApplied)
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.selectedEntry?.title, local.title)
        XCTAssertEqual(try Data(contentsOf: copy), externalBytes)

        store.run(.reload)
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.isDirty)
        XCTAssertFalse(store.hasDraft)
        XCTAssertNotEqual(store.editorGeneration, editorGeneration)
        XCTAssertEqual(store.selectedEntry?.title, external.title)
        XCTAssertEqual(try Data(contentsOf: copy), externalBytes)
        var recovered = try XCTUnwrap(store.selectedEntry)
        recovered.notes = "Saved after Reload Latest"
        store.updateItem(recovered)
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.isDirty)
    }

    func testMonitorHandlesInPlaceWritesRepeatedReplacementsAndStopsOnLock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("shared.kdbx")
        let staging = directory.appendingPathComponent("staging.kdbx")
        try FileManager.default.copyItem(at: fixture(), to: copy)
        try FileManager.default.copyItem(at: fixture(), to: staging)
        let store = VaultStore()
        store.openFile(copy)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        let id = try XCTUnwrap(store.selectedItemID)
        let other = RustVaultRepository(url: staging)
        _ = try await other.load(password: "fixture-password", keyFile: nil)
        defer { other.lock(); store.lock() }
        for (index, options) in [Data.WritingOptions(), .atomic, .atomic].enumerated() {
            var entry = try await other.entry(id)
            entry.title = "External replacement \(index)"
            _ = try await other.execute(.updateEntry(entry))
            try Data(contentsOf: staging).write(to: copy, options: options)
            let deadline = Date().addingTimeInterval(3)
            while store.selectedEntry?.title != entry.title && Date() < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(store.selectedEntry?.title, entry.title)
            XCTAssertNil(store.operationFailure)
        }
        store.lock()
        try Data(contentsOf: staging).write(to: copy, options: .atomic)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.state, .locked)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.selectedEntry)
        XCTAssertNil(store.operationFailure)
    }

    func testExternalDeletionReconcilesSelectionAndGroupChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("shared.kdbx")
        try FileManager.default.copyItem(at: fixture(), to: copy)
        let store = VaultStore()
        store.openFile(copy)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        defer { store.lock() }
        let deleted = try XCTUnwrap(store.selectedItemID)
        let other = RustVaultRepository(url: copy)
        let vault = try await other.load(password: "fixture-password", keyFile: nil)
        defer { other.lock() }
        let root = try XCTUnwrap(vault.groups.first { $0.parentID == nil })
        _ = try await other.execute(.renameGroup(root.id, "External root"))
        _ = try await other.execute(.deleteEntry(deleted))
        _ = try await other.execute(.deleteEntryPermanently(deleted))
        let deadline = Date().addingTimeInterval(3)
        while (store.items.contains { $0.id == deleted } || store.selectedEntry == nil) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(store.items.contains { $0.id == deleted })
        XCTAssertNotEqual(store.selectedItemID, deleted)
        XCTAssertEqual(store.selectedEntry?.id, store.selectedItemID)
        XCTAssertEqual(store.groups.first { $0.id == root.id }?.name, "External root")
        XCTAssertEqual(store.vaultName, "KeeLocker Integration Vault")
        XCTAssertNil(store.operationFailure)
    }

    func testFileMonitoringFollowsSaveAsDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.kdbx")
        let destination = directory.appendingPathComponent("copy.kdbx")
        try FileManager.default.copyItem(at: fixture(), to: original)
        let store = VaultStore()
        store.openFile(original)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        defer { store.lock() }
        let id = try XCTUnwrap(store.selectedItemID)
        let originalTitle = try XCTUnwrap(store.selectedEntry?.title)
        store.run(.saveAs(destination))
        await store.waitForOperation()
        XCTAssertEqual(store.fileURL?.resolvingSymlinksInPath(), destination.resolvingSymlinksInPath())
        let old = RustVaultRepository(url: original)
        _ = try await old.load(password: "fixture-password", keyFile: nil)
        defer { old.lock() }
        var ignored = try await old.entry(id)
        ignored.title = "Changed previous file"
        _ = try await old.execute(.updateEntry(ignored))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.selectedEntry?.title, originalTitle)

        let current = RustVaultRepository(url: destination)
        _ = try await current.load(password: "fixture-password", keyFile: nil)
        defer { current.lock() }
        var expected = try await current.entry(id)
        expected.title = "Changed current file"
        _ = try await current.execute(.updateEntry(expected))
        let deadline = Date().addingTimeInterval(3)
        while store.selectedEntry?.title != expected.title && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(store.selectedEntry?.title, expected.title)
        XCTAssertNil(store.operationFailure)
    }

    func testFavoritePersistsInFileAndCanBeRemovedFromFavorites() async throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kdbx")
        try FileManager.default.copyItem(at: fixture(), to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(atPath: copy.path + ".bak")
        }
        let store = VaultStore()
        store.openFile(copy)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        XCTAssertTrue(store.capabilities.canFavorite)
        var entry = try XCTUnwrap(store.selectedEntry)
        let originalPassword = entry.password
        let originalTags = entry.tags
        entry.isFavorite = true
        store.updateItem(entry)
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.favoriteCount, 1)

        store.lock()
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        store.navigate(to: .favorites)
        await store.waitForSelection()
        XCTAssertEqual(store.visibleItems.map(\.id), [entry.id])
        var reopened = try XCTUnwrap(store.selectedEntry)
        XCTAssertTrue(reopened.isFavorite)
        XCTAssertEqual(reopened.password, originalPassword)
        XCTAssertEqual(reopened.tags, originalTags)

        reopened.title = "Edited favorite"
        store.updateItem(reopened)
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        reopened = try XCTUnwrap(store.selectedEntry)
        XCTAssertTrue(reopened.isFavorite)
        reopened.isFavorite = false
        store.updateItem(reopened)
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        XCTAssertTrue(store.visibleItems.isEmpty)
        XCTAssertNil(store.selectedItemID)
        XCTAssertEqual(store.favoriteCount, 0)

        store.lock()
        let repository = RustVaultRepository(url: copy)
        let vault = try await repository.load(password: "fixture-password", keyFile: nil)
        XCTAssertFalse(vault.entries.contains(where: \.isFavorite))
        let saved = try await repository.entry(entry.id)
        XCTAssertEqual(saved.password, originalPassword)
        XCTAssertEqual(saved.tags, originalTags)
        repository.lock()
    }

    private func fixture(_ name: String = "interop") -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).kdbx")
    }

    func testRustBridgeCryptoMatrix() async throws {
        for version in ["40", "41"] {
            for kdf in ["argon2d", "argon2id"] {
                for cipher in ["aes", "chacha20"] {
                    for keyed in [false, true] {
                        let name = "Matrix/xc-\(version)-\(kdf)-\(cipher)\(keyed ? "-key" : "")"
                        let repository = RustVaultRepository(url: fixture(name))
                        let keyFile = keyed ? fixture().deletingLastPathComponent().appendingPathComponent("Matrix/test.key") : nil
                        let vault = try await repository.load(password: "fixture-password", keyFile: keyFile)
                        let summary = try XCTUnwrap(vault.entries.first { $0.title == "XC created" })
                        XCTAssertTrue(summary.password.isEmpty)
                        let entry = try await repository.entry(summary.id)
                        XCTAssertEqual(entry.password, "xc-password")
                        repository.lock()
                    }
                }
            }
        }
    }

    func testRustBridgeCommandsSaveReopenAndLock() async throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kdbx")
        try FileManager.default.copyItem(at: fixture("Matrix/xc-41-argon2id-chacha20"), to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(atPath: copy.path + ".bak")
        }
        let store = VaultStore()
        store.openFile(copy)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        let root = try XCTUnwrap(store.groups.first { $0.parentID == nil })
        store.run(.createGroup(parent: root.id, name: "Created in Swift"))
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.isDirty)
        let group = try XCTUnwrap(store.groups.first { $0.name == "Created in Swift" })
        store.navigate(to: .group(group))
        store.addItem()
        var entry = try XCTUnwrap(store.newItemDraft)
        entry.title = "Swift command roundtrip"
        entry.password = "test-only-password"
        let created = await store.saveItem(entry)
        XCTAssertTrue(created)
        entry = try XCTUnwrap(store.selectedEntry)
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.isDirty)
        store.run(.moveEntry(entry.id, root.id))
        await store.waitForOperation()
        store.run(.deleteGroup(group.id))
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.isDirty)
        store.lock()
        XCTAssertNil(store.selectedEntry)
        XCTAssertTrue(store.items.isEmpty)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        store.selectedItemID = entry.id
        await store.waitForSelection()
        XCTAssertEqual(store.selectedEntry?.password, "test-only-password")
        XCTAssertEqual(store.selectedEntry?.group.id, root.id)
        store.run(.deleteEntry(entry.id))
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.isDirty)
        store.lock()
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        XCTAssertFalse(store.activeItems.contains { $0.id == entry.id })
        XCTAssertTrue(store.isInRecycleBin(id: entry.id))
        store.run(.deleteEntryPermanently(entry.id))
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.items.contains { $0.id == entry.id })
        store.lock()
    }

    func testKeePassXCFieldsHierarchySearchEditSaveAndLock() async throws {
        let url = fixture()
        let originalBytes = try Data(contentsOf: url)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kdbx")
        try FileManager.default.copyItem(at: url, to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(atPath: copy.path + ".bak")
        }
        let store = VaultStore()
        XCTAssertEqual(store.state, .noVault)
        store.openFile(copy)
        XCTAssertEqual(store.state, .locked)
        store.unlock(password: "fixture-password")
        XCTAssertEqual(store.state, .unlocking)
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .unlocked)
        XCTAssertEqual(store.vaultName, "KeeLocker Integration Vault")
        XCTAssertEqual(store.capabilities, .persistent)
        XCTAssertEqual(store.items.count, 2)
        let shared = store.groups.filter { $0.name == "Shared" }
        XCTAssertEqual(shared.count, 2)
        XCTAssertEqual(Set(shared.map(\.id)).count, 2)
        XCTAssertNotEqual(shared.first?.parentID, shared.last?.parentID)
        XCTAssertTrue(store.groups.contains { $0.name == "Empty" })
        let summary = try XCTUnwrap(store.items.first { $0.title == "GitHub тест 🔐" })
        XCTAssertTrue(summary.password.isEmpty)
        store.selectedItemID = summary.id
        await store.waitForSelection()
        let entry = try XCTUnwrap(store.selectedEntry)
        XCTAssertEqual(entry.username, "developer@example.test")
        XCTAssertEqual(entry.password, "pässword-🔐-test")
        XCTAssertEqual(entry.website, "https://example.test/login")
        XCTAssertEqual(entry.notes, "First line\nSecond line — заметка")
        XCTAssertEqual(Set(entry.tags), Set(["work", "important", "тест"]))
        XCTAssertEqual(entry.createdAt, ISO8601DateFormatter().date(from: "2024-01-02T03:04:05Z"))
        XCTAssertEqual(entry.modifiedAt, ISO8601DateFormatter().date(from: "2024-06-07T08:09:10Z"))
        let secret = try XCTUnwrap(entry.customFields.first { $0.name == "Recovery code" })
        XCTAssertTrue(secret.isSensitive)
        XCTAssertEqual(secret.value, "recovery-secret")
        XCTAssertEqual(entry.customFields.first { $0.name == "Account ID" }?.value, "account-42")
        for query in ["github", "заметка", "important", "account-42"] {
            store.searchQuery = query
            XCTAssertEqual(store.visibleItems.map(\.id), [entry.id])
        }
        store.searchQuery = "recovery-secret"
        XCTAssertTrue(store.visibleItems.isEmpty)
        store.navigate(to: .group(entry.group))
        XCTAssertEqual(store.visibleItems.map(\.id), [entry.id])
        var edited = entry
        edited.title = "Saved edit"
        store.updateItem(edited)
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.isDirty)
        let reopened = RustVaultRepository(url: copy)
        _ = try await reopened.load(password: "fixture-password", keyFile: nil)
        let saved = try await reopened.entry(entry.id)
        XCTAssertEqual(saved.title, "Saved edit")
        XCTAssertEqual(saved.password, entry.password)
        XCTAssertEqual(saved.customFields.first { $0.name == "Recovery code" }?.value, "recovery-secret")
        reopened.lock()
        store.lock()
        XCTAssertEqual(store.state, .locked)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.selectedItemID)
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .unlocked)
    }

    func testAutosaveConflictKeepsEditInMemoryAndAllowsSaveAs() async throws {
        let suite = "KeeLockerTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kdbx")
        let recovered = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kdbx")
        try FileManager.default.copyItem(at: fixture(), to: copy)
        defer {
            for url in [copy, recovered] {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(atPath: url.path + ".bak")
            }
        }
        let store = VaultStore(preferences: preferences)
        store.openFile(copy)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        // The fixture contains multiple entries; the initial HashMap order is not stable.
        store.selectedItemID = try XCTUnwrap(store.items.first { $0.title.hasPrefix("GitHub") }?.id)
        await store.waitForSelection()
        var edited = try XCTUnwrap(store.selectedEntry)
        edited.title = "Recovered unsaved edit"

        let externalBytes = try Data(contentsOf: copy) + Data([0])
        try externalBytes.write(to: copy)
        store.updateItem(edited)
        await store.waitForOperation()

        XCTAssertEqual(store.operationFailure, .conflict)
        XCTAssertTrue(store.lastCommandApplied)
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.items.first { $0.id == edited.id }?.title, edited.title)
        XCTAssertEqual(try Data(contentsOf: copy), externalBytes)

        store.run(.saveAs(recovered))
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.isDirty)
        store.lock()
        let relaunched = VaultStore(preferences: preferences)
        XCTAssertEqual(relaunched.fileURL?.resolvingSymlinksInPath(), recovered.resolvingSymlinksInPath())
        XCTAssertEqual(relaunched.state, .locked)
        let reopened = RustVaultRepository(url: recovered)
        _ = try await reopened.load(password: "fixture-password", keyFile: nil)
        let saved = try await reopened.entry(edited.id)
        XCTAssertEqual(saved.password, edited.password)
        XCTAssertEqual(saved.customFields.first { $0.name == "Recovery code" }?.value, "recovery-secret")
        XCTAssertEqual(saved.title, edited.title)
        reopened.lock()
    }

    func testWrongPasswordCanRetry() async {
        let store = VaultStore()
        store.openFile(fixture())
        store.unlock(password: "wrong")
        await store.waitForUnlock()
        XCTAssertEqual(store.failure, .wrongPassword)
        XCTAssertTrue(store.items.isEmpty)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .unlocked)
    }

    func testEmptyDatabaseNameUsesFilenameInsteadOfRootGroup() async throws {
        let vault = try await RustVaultRepository(url: fixture("filename-fallback"))
            .load(password: "fixture-password", keyFile: nil)
        XCTAssertEqual(vault.name, "filename-fallback")
        XCTAssertNotEqual(vault.name, vault.groups.first?.name)
    }

    func testFileFailuresAreSanitized() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kdbx")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VaultStore()
        store.openFile(url)
        store.unlock(password: "unused")
        await store.waitForUnlock()
        XCTAssertEqual(store.failure, .failedToReadFile)
        try Data("not a database at all".utf8).write(to: url)
        store.unlock(password: "unused")
        await store.waitForUnlock()
        XCTAssertEqual(store.failure, .unsupportedDatabase)
        let bytes = try Data(contentsOf: fixture())
        try Data(bytes.prefix(16)).write(to: url)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        XCTAssertEqual(store.failure, .corruptedDatabase)
        var corrupted = try Data(contentsOf: fixture())
        corrupted[corrupted.count - 40] ^= 0x01
        try corrupted.write(to: url)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        XCTAssertEqual(store.failure, .corruptedDatabase)
    }

    func testMemoryRepositoryRetainsEditsAcrossLock() async throws {
        let store = VaultStore(items: MockVault.items)
        store.addItem()
        let draft = try XCTUnwrap(store.newItemDraft)
        let saved = await store.saveItem(draft)
        XCTAssertTrue(saved)
        store.lock()
        XCTAssertTrue(store.items.isEmpty)
        store.unlock()
        await store.waitForUnlock()
        XCTAssertEqual(store.items.count, 10)
        XCTAssertEqual(store.items.first?.title, "New login")
        XCTAssertEqual(store.capabilities, .editable)
    }

    func testLateCompletionAfterLockAndReplacementIsDiscarded() async {
        let slow = SuspendedRepository()
        let store = VaultStore()
        store.use(slow)
        store.unlock(password: "test")
        while slow.continuation == nil { await Task.yield() }
        store.lock()
        store.openDemo()
        await store.waitForUnlock()
        slow.continuation?.resume(returning: Vault(name: "Stale secret vault", groups: [], entries: []))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(store.vaultName, "Personal Vault")
        XCTAssertEqual(store.items.count, 9)
    }
}

@MainActor
final class VaultSaveWarningTests: XCTestCase {
    func testSaveWriteFailureAdoptsDirtySnapshotAndRetryClearsWarning() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.kdbx")
        try Data("synthetic source".utf8).write(to: source)
        let native = DirectorySyncWarningVault(path: source.path)
        let repository = RustVaultRepository(url: source, opening: FixedVaultOpening(vault: native))
        let store = VaultStore()
        store.use(repository, fileURL: source)
        store.unlock(password: "synthetic")
        await store.waitForUnlock()
        defer { store.lock() }
        let originalRefreshes = native.refreshes
        store.run(.save)
        await store.waitForOperation()
        XCTAssertEqual(store.operationFailure, .writeFailed)
        XCTAssertTrue(store.isDirty, "Adopt Rust's durability-warning snapshot")
        store.refreshFromDisk()
        await store.waitForRefresh()
        XCTAssertEqual(native.refreshes, originalRefreshes, "Keep refresh deferred while durability is uncertain")
        store.run(.save)
        await store.waitForOperation()
        XCTAssertFalse(store.isDirty)
        XCTAssertNil(store.operationFailure)
    }

    func testCommittedSaveAsWriteFailureAdoptsDestinationAndMovesMonitoring() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceDirectory = directory.appendingPathComponent("source")
        let destinationDirectory = directory.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("source.kdbx")
        let destination = destinationDirectory.appendingPathComponent("copy.kdbx")
        let original = Data("synthetic source".utf8)
        try original.write(to: source)
        let native = DirectorySyncWarningVault(path: source.path)
        let repository = RustVaultRepository(url: source, opening: FixedVaultOpening(vault: native))
        let store = VaultStore()
        store.use(repository, fileURL: source)
        store.unlock(password: "synthetic")
        await store.waitForUnlock()
        defer { store.lock() }
        store.run(.saveAs(destination))
        await store.waitForOperation()
        XCTAssertEqual(store.operationFailure, .writeFailed)
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.fileURL?.path, destination.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: source), original)
        store.run(.save)
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.isDirty)
        // The directories differ: a watcher left at the original path cannot
        // observe this write. No explicit refresh call is made here.
        try DirectorySyncWarningVault.externalBytes.write(to: destination, options: .atomic)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while store.vaultName != "Externally refreshed destination", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(store.vaultName, "Externally refreshed destination")
        XCTAssertEqual(store.fileURL?.path, destination.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    func testUncommittedSaveAsWriteFailureKeepsOriginalPathAndCleanState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.kdbx")
        let destination = directory.appendingPathComponent("copy.kdbx")
        try Data("synthetic source".utf8).write(to: source)
        let native = DirectorySyncWarningVault(path: source.path, failBeforeCommit: true)
        let repository = RustVaultRepository(url: source, opening: FixedVaultOpening(vault: native))
        let store = VaultStore()
        store.use(repository, fileURL: source)
        store.unlock(password: "synthetic")
        await store.waitForUnlock()
        defer { store.lock() }
        store.run(.saveAs(destination))
        await store.waitForOperation()
        XCTAssertEqual(store.operationFailure, .writeFailed)
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.fileURL?.path, source.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct FixedVaultOpening: RustVaultOpening {
    let vault: CoreVault
    func open(path: String, password: String, keyFile: String?) throws -> CoreVault { vault }
    func open(path: String, keyMaterial: Data) throws -> CoreVault { vault }
}

/// Implements the Rust post-commit WriteFailed contract without crypto or fault
/// injection into unrelated filesystem operations. Files contain synthetic bytes.
private final class DirectorySyncWarningVault: CoreVault, @unchecked Sendable {
    static let externalBytes = Data("synthetic external change".utf8)
    private let mutex = NSLock()
    private var path: String
    private var dirty = false
    private var name = "Synthetic save-warning vault"
    private var warnOnSave = true
    private var refreshCount = 0
    private let failBeforeCommit: Bool
    init(path: String, failBeforeCommit: Bool = false) {
        self.path = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        self.failBeforeCommit = failBeforeCommit
        super.init(noHandle: NoHandle())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("Synthetic sessions have no native handle") }
    var refreshes: Int {
        mutex.lock()
        defer { mutex.unlock() }
        return refreshCount
    }
    override func snapshot() throws -> CoreSnapshot {
        mutex.lock()
        defer { mutex.unlock() }
        return CoreSnapshot(info: CoreVaultInfo(name: name, path: path, dirty: dirty, rootId: UUID().uuidString, recycleBinId: nil, recycleBinEnabled: true),
                            groups: [], entries: [], customIcons: [])
    }
    override func save() throws {
        mutex.lock()
        defer { mutex.unlock() }
        if warnOnSave {
            warnOnSave = false
            dirty = true
            throw CoreError.WriteFailed
        }
        dirty = false
    }
    override func saveAs(path: String) throws {
        mutex.lock()
        defer { mutex.unlock() }
        guard !failBeforeCommit else { throw CoreError.WriteFailed }
        let destination = URL(fileURLWithPath: path)
        try Data("synthetic committed copy".utf8).write(to: destination, options: .atomic)
        self.path = destination.resolvingSymlinksInPath().standardizedFileURL.path
        dirty = true
        warnOnSave = false
        throw CoreError.WriteFailed
    }
    override func reloadIfChanged() throws -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        refreshCount += 1
        guard try Data(contentsOf: URL(fileURLWithPath: path)) == Self.externalBytes,
              name != "Externally refreshed destination" else { return false }
        name = "Externally refreshed destination"
        return true
    }
    override func lock() {}
}

@MainActor
final class VaultLoadAdmissionTests: XCTestCase {
    func testAlreadyCancelledLoadCannotSupersedeTheAdaptersActiveOpen() async throws {
        let admission = VaultLoadAdmission()
        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).kdbx")
        try Data("synthetic admission identity".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let gate = SynchronousLoadGate()
        defer { gate.release() }
        let repository = RustVaultRepository(url: url, loadAdmission: admission,
                                             opening: SyntheticVaultOpening(path: url.path, openGate: gate))
        defer { repository.lock() }
        let activeLoad = Task { try await repository.load(password: "synthetic", keyFile: nil) }
        try await reached { gate.entered }
        let cancelledLoad = Task { try await repository.load(password: "cancelled-synthetic", keyFile: nil) }
        cancelledLoad.cancel() // Cancel before this main-actor task can enter the adapter.
        do { _ = try await cancelledLoad.value; XCTFail("An already cancelled request was accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        gate.release()
        let vault = try await activeLoad.value
        XCTAssertEqual(vault.name, "Synthetic admitted vault")
    }

    func testCancelledOpenHoldsAdmissionThroughLateSessionLockAndOtherVaultCanOpen() async throws {
        let admission = VaultLoadAdmission()
        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).kdbx")
        try Data("synthetic admission identity".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let openGate = SynchronousLoadGate()
        let lockGate = SynchronousLoadGate()
        defer { openGate.release(); lockGate.release() }
        let oldOpening = SyntheticVaultOpening(path: url.path, openGate: openGate, lockGate: lockGate)
        let oldRepository = RustVaultRepository(url: url, loadAdmission: admission, opening: oldOpening)
        let oldLoad = Task { try await oldRepository.load(password: "synthetic", keyFile: nil) }
        try await reached { openGate.entered }
        oldLoad.cancel()
        oldRepository.lock()

        let latestOpening = SyntheticVaultOpening(path: url.path)
        let latestRepository = RustVaultRepository(url: url, loadAdmission: admission, opening: latestOpening)
        defer { latestRepository.lock() }
        let latestLoad = Task { try await latestRepository.load(keyMaterial: Data(repeating: 1, count: 36)) }
        try await reached { admission.queuedRequest(for: url) != nil }
        XCTAssertFalse(latestOpening.openGate.entered, "Cancelling a running synchronous call must not release its slot")

        let otherURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).kdbx")
        try Data("another synthetic admission identity".utf8).write(to: otherURL)
        defer { try? FileManager.default.removeItem(at: otherURL) }
        let otherOpening = SyntheticVaultOpening(path: otherURL.path)
        let otherRepository = RustVaultRepository(url: otherURL, loadAdmission: admission, opening: otherOpening)
        _ = try await otherRepository.load(password: "synthetic", keyFile: nil)
        otherRepository.lock()
        XCTAssertTrue(otherOpening.openGate.entered, "Unrelated vaults must not wait behind this KDF")

        openGate.release()
        try await reached { lockGate.entered }
        XCTAssertFalse(latestOpening.openGate.entered, "Keep admission until the rejected session is actually closed")
        lockGate.release()
        do { _ = try await oldLoad.value; XCTFail("A cancelled open was published") }
        catch { XCTAssertTrue(error is CancellationError) }
        let vault = try await latestLoad.value
        XCTAssertEqual(vault.fileURL?.path, url.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertTrue(latestOpening.openGate.entered)
    }

    func testRetriesAcrossAdaptersAndAliasesKeepOnlyLatestQueuedOpen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.kdbx")
        let alias = directory.appendingPathComponent("alias.kdbx")
        try Data("synthetic admission identity".utf8).write(to: url)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        // Use the production shared coordinator across successive repository instances.
        let admission = VaultLoadAdmission.shared
        let gate = SynchronousLoadGate()
        defer { gate.release() }
        let activeRepository = RustVaultRepository(url: url, opening: SyntheticVaultOpening(path: url.path, openGate: gate))
        defer { activeRepository.lock() }
        let activeLoad = Task { try await activeRepository.load(password: "synthetic", keyFile: nil) }
        try await reached { gate.entered }

        let obsoleteOpening = SyntheticVaultOpening(path: url.path)
        let obsoleteRepository = RustVaultRepository(url: alias, opening: obsoleteOpening)
        let obsoleteLoad = Task { try await obsoleteRepository.load(password: "obsolete-synthetic", keyFile: nil) }
        try await reached { admission.queuedRequest(for: url) != nil }
        let obsoleteRequest = try XCTUnwrap(admission.queuedRequest(for: url))
        let latestOpening = SyntheticVaultOpening(path: url.path)
        let latestRepository = RustVaultRepository(url: url, opening: latestOpening)
        defer { latestRepository.lock() }
        let latestLoad = Task { try await latestRepository.load(password: "latest-synthetic", keyFile: nil) }
        try await reached { admission.queuedRequest(for: url)?.id != obsoleteRequest.id }
        do { _ = try await obsoleteLoad.value; XCTFail("An obsolete queued retry was admitted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(obsoleteOpening.openGate.entered)
        XCTAssertFalse(latestOpening.openGate.entered)
        gate.release()
        _ = try await activeLoad.value
        _ = try await latestLoad.value
        XCTAssertTrue(latestOpening.openGate.entered)
    }

    func testCancellingOrLockingAQueuedRepositoryNeverStartsItsOpen() async throws {
        for cancelTask in [false, true] {
            let admission = VaultLoadAdmission()
            let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).kdbx")
            try Data("synthetic admission identity".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let gate = SynchronousLoadGate()
            defer { gate.release() }
            let activeRepository = RustVaultRepository(url: url, loadAdmission: admission,
                                                      opening: SyntheticVaultOpening(path: url.path, openGate: gate))
            let activeLoad = Task { try await activeRepository.load(password: "synthetic", keyFile: nil) }
            try await reached { gate.entered }
            let queuedOpening = SyntheticVaultOpening(path: url.path)
            let queuedRepository = RustVaultRepository(url: url, loadAdmission: admission, opening: queuedOpening)
            let queuedLoad = Task { try await queuedRepository.load(password: "synthetic", keyFile: nil) }
            try await reached { admission.queuedRequest(for: url) != nil }
            if cancelTask { queuedLoad.cancel() } else { queuedRepository.lock() }
            do { _ = try await queuedLoad.value; XCTFail("A cancelled queued request was admitted") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertNil(admission.queuedRequest(for: url))
            XCTAssertFalse(queuedOpening.openGate.entered)
            gate.release()
            _ = try await activeLoad.value
            activeRepository.lock()
        }
    }

    private func reached(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "The source gate was not reached")
        if !condition() { throw CancellationError() }
    }
}

/// Models a synchronous FFI call that ignores Swift task cancellation.
private final class SynchronousLoadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released: Bool
    private var didEnter = false
    init(released: Bool = false) { self.released = released }
    var entered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return didEnter
    }
    func wait() {
        condition.lock()
        didEnter = true
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private struct CatalogRaceOpening: RustVaultOpening {
    let gate: SynchronousLoadGate
    let readsHistory: Bool
    func open(path: String, password: String, keyFile: String?) throws -> CoreVault {
        CatalogRaceVault(base: try CoreVault.open(path: path, password: password, keyFile: keyFile),
                         gate: gate, readsHistory: readsHistory)
    }
    func open(path: String, keyMaterial: Data) throws -> CoreVault { throw VaultFailure.invalidOperation }
}

private struct SnapshotVaultOpening: RustVaultOpening {
    let source: CoreSnapshot
    func open(path: String, password: String, keyFile: String?) throws -> CoreVault { SnapshotCoreVault(source: source) }
    func open(path: String, keyMaterial: Data) throws -> CoreVault { SnapshotCoreVault(source: source) }
}

private final class SnapshotCoreVault: CoreVault, @unchecked Sendable {
    let source: CoreSnapshot
    init(source: CoreSnapshot) { self.source = source; super.init(noHandle: NoHandle()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("Synthetic snapshot has no native handle") }
    override func snapshot() throws -> CoreSnapshot { source }
    override func lock() {}
}

private final class CatalogRaceVault: CoreVault, @unchecked Sendable {
    let base: CoreVault
    let gate: SynchronousLoadGate
    let readsHistory: Bool
    init(base: CoreVault, gate: SynchronousLoadGate, readsHistory: Bool) {
        self.base = base
        self.gate = gate
        self.readsHistory = readsHistory
        super.init(noHandle: NoHandle())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("Test wrapper has no native handle") }
    override func snapshot() throws -> CoreSnapshot { try base.snapshot() }
    override func entry(id: String) throws -> CoreEntry {
        if !readsHistory { gate.wait() }
        return try base.entry(id: id)
    }
    override func history(entry: String) throws -> [CoreEntry] {
        if readsHistory { gate.wait() }
        return try base.history(entry: entry)
    }
    override func inspectEntry(id: String, includeHistory: Bool) throws -> CoreEntryInspection {
        gate.wait()
        return try base.inspectEntry(id: id, includeHistory: includeHistory)
    }
    override func reloadIfChanged() throws -> Bool { try base.reloadIfChanged() }
    override func lock() { base.lock() }
}

private struct SyntheticVaultOpening: RustVaultOpening {
    let path: String
    let openGate: SynchronousLoadGate
    let lockGate: SynchronousLoadGate
    init(path: String, openGate: SynchronousLoadGate = SynchronousLoadGate(released: true),
         lockGate: SynchronousLoadGate = SynchronousLoadGate(released: true)) {
        self.path = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        self.openGate = openGate
        self.lockGate = lockGate
    }
    func open(path: String, password: String, keyFile: String?) throws -> CoreVault { try open(path: path) }
    func open(path: String, keyMaterial: Data) throws -> CoreVault { try open(path: path) }
    private func open(path: String) throws -> CoreVault {
        guard path == self.path else { throw VaultFailure.failedToReadFile }
        openGate.wait()
        return SyntheticOpenedVault(path: path, lockGate: lockGate)
    }
}

private final class SyntheticOpenedVault: CoreVault, @unchecked Sendable {
    private let path: String
    private let lockGate: SynchronousLoadGate
    init(path: String, lockGate: SynchronousLoadGate) {
        self.path = path
        self.lockGate = lockGate
        super.init(noHandle: NoHandle())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("Synthetic sessions have no native handle") }
    override func snapshot() throws -> CoreSnapshot {
        CoreSnapshot(info: CoreVaultInfo(name: "Synthetic admitted vault", path: path, dirty: false, rootId: UUID().uuidString, recycleBinId: nil, recycleBinEnabled: true),
                     groups: [], entries: [], customIcons: [])
    }
    override func lock() { lockGate.wait() }
}

@MainActor
private final class CappedHistoryRepository: VaultRepository {
    let capabilities = VaultCapabilities.persistent
    let requiresPassword = false
    var vault: Vault
    var version: VaultEntry

    init() {
        var entry = MockVault.items[0]
        entry.title = "Synthetic v1"
        entry.historyCount = 1
        entry.modifiedAt = Date(timeIntervalSince1970: 1_000)
        vault = Vault(name: "Synthetic capped history", groups: [entry.group], entries: [entry])
        version = entry
        version.title = "Synthetic v0"
    }

    func load(password: String, keyFile: URL?) async throws -> Vault { vault }
    func execute(_ command: VaultCommand) async throws -> VaultCommandResult {
        guard case .putAttachment(_, let name, let data) = command else { throw VaultFailure.invalidOperation }
        version = vault.entries[0]
        vault.entries[0].attachments = [AttachmentMetadata(name: name, size: UInt64(data.count))]
        return VaultCommandResult(vault: vault)
    }
    func entry(_ id: UUID) async throws -> VaultEntry { vault.entries[0] }
    func history(_ id: UUID) async throws -> [VaultEntry] { [version] }
    func lock() {}
}

@MainActor
private final class SuspendedSelectionRepository: VaultRepository {
    let capabilities = VaultCapabilities.editable
    let requiresPassword = false
    private let memory = MemoryVaultRepository()
    var continuation: CheckedContinuation<VaultEntry, Error>?
    var suspendAfterCreation = false
    var suspendedEntry: VaultEntry?
    private var suspendsSelection = false
    var currentEntry: VaultEntry { memory.vault.entries[0] }
    func completeSelection(_ result: Result<VaultEntry, Error>) {
        suspendsSelection = false
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
    func load(password: String, keyFile: URL?) async throws -> Vault { memory.vault }
    func entry(_ id: UUID) async throws -> VaultEntry {
        if suspendsSelection {
            suspendedEntry = try await memory.entry(id)
            return try await withCheckedThrowingContinuation {
                // Selection may be requested again after reconciliation. Retire
                // the fake's obsolete waiter instead of leaking its continuation.
                continuation?.resume(throwing: CancellationError())
                continuation = $0
            }
        }
        return try await memory.entry(id)
    }
    func execute(_ command: VaultCommand) async throws -> VaultCommandResult {
        let result = try await memory.execute(command)
        if case .createEntry = command, suspendAfterCreation { suspendsSelection = true }
        return result
    }
    func refresh() async throws -> Vault? {
        var entries = memory.vault.entries
        entries[0].username = "Externally refreshed username"
        memory.replaceEntries(entries)
        suspendsSelection = true
        return memory.vault
    }
}

@MainActor
private final class RejectFirstCreationRepository: VaultRepository {
    let capabilities = VaultCapabilities.editable
    let requiresPassword = false
    private let memory = MemoryVaultRepository()
    private var rejectNextCreate = true
    func load(password: String, keyFile: URL?) async throws -> Vault { memory.vault }
    func entry(_ id: UUID) async throws -> VaultEntry { try await memory.entry(id) }
    func execute(_ command: VaultCommand) async throws -> VaultCommandResult {
        if case .createEntry = command, rejectNextCreate {
            rejectNextCreate = false
            throw VaultFailure.invalidOperation
        }
        return try await memory.execute(command)
    }
}

@MainActor
private final class SuspendedRepository: VaultRepository {
    let capabilities = VaultCapabilities.readOnly
    let requiresPassword = true
    var continuation: CheckedContinuation<Vault, Error>?
    func execute(_ command: VaultCommand) async throws -> VaultCommandResult { throw VaultFailure.invalidOperation }
    func entry(_ id: UUID) async throws -> VaultEntry { throw VaultFailure.invalidOperation }

    func load(password: String, keyFile: URL?) async throws -> Vault {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

@MainActor
private final class SuspendedRefreshRepository: VaultRepository {
    let capabilities = VaultCapabilities.editable
    let requiresPassword = false
    private let memory = MemoryVaultRepository()
    var continuation: CheckedContinuation<Vault?, Error>?
    private(set) var commandCount = 0
    func load(password: String, keyFile: URL?) async throws -> Vault { memory.vault }
    func entry(_ id: UUID) async throws -> VaultEntry { try await memory.entry(id) }
    func execute(_ command: VaultCommand) async throws -> VaultCommandResult {
        commandCount += 1
        return try await memory.execute(command)
    }
    func refresh() async throws -> Vault? {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

@MainActor
private final class InitialSelectionRepository: VaultRepository {
    let capabilities = VaultCapabilities.persistent
    let requiresPassword = false
    private let memory = MemoryVaultRepository()
    var selection: CheckedContinuation<VaultEntry, Never>?
    private(set) var refreshes = 0
    private(set) var commands = 0
    var entry: VaultEntry { memory.vault.entries[0] }
    func load(password: String, keyFile: URL?) async throws -> Vault { memory.vault }
    func refresh() async throws -> Vault? { refreshes += 1; return nil }
    func entry(_ id: UUID) async throws -> VaultEntry {
        await withCheckedContinuation { selection = $0 }
    }
    func execute(_ command: VaultCommand) async throws -> VaultCommandResult {
        commands += 1
        throw VaultFailure.invalidOperation
    }
}
