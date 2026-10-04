import XCTest
@testable import KeeLocker

@MainActor
final class VaultStoreTests: XCTestCase {
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
        repository.continuation?.resume(returning: try XCTUnwrap(repository.suspendedEntry))
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
        repository.continuation?.resume(throwing: VaultFailure.failedToReadFile)
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
        repository.continuation?.resume(returning: repository.currentEntry)
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
private final class SuspendedSelectionRepository: VaultRepository {
    let capabilities = VaultCapabilities.editable
    let requiresPassword = false
    private let memory = MemoryVaultRepository()
    var continuation: CheckedContinuation<VaultEntry, Error>?
    var suspendAfterCreation = false
    var suspendedEntry: VaultEntry?
    private var suspendsSelection = false
    var currentEntry: VaultEntry { memory.vault.entries[0] }
    func load(password: String, keyFile: URL?) async throws -> Vault { memory.vault }
    func entry(_ id: UUID) async throws -> VaultEntry {
        if suspendsSelection {
            suspendedEntry = try await memory.entry(id)
            return try await withCheckedThrowingContinuation { continuation = $0 }
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
