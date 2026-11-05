import XCTest
@testable import KeeLocker

@MainActor
final class AppUpdateTests: XCTestCase {
    func testUpdateChannelDefaultsAndFiltering() {
        XCTAssertEqual(UpdateChannel.resolve(saved: nil, bundled: "stable"), .stable)
        XCTAssertEqual(UpdateChannel.resolve(saved: nil, bundled: "beta"), .beta)
        XCTAssertEqual(UpdateChannel.resolve(saved: "stable", bundled: "beta"), .stable)
        XCTAssertEqual(UpdateChannel.resolve(saved: "beta", bundled: "stable"), .beta)
        XCTAssertEqual(UpdateChannel.resolve(saved: "unknown", bundled: "unknown"), .stable)
        XCTAssertTrue(UpdateChannel.stable.allowedChannels.isEmpty)
        XCTAssertEqual(UpdateChannel.beta.allowedChannels, ["beta"])
    }

    func testUpdateChannelPreferenceSurvivesRestartAndNewBuildDefault() throws {
        let name = "com.keelocker.update-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let updater = AppUpdater(defaults: defaults, bundledChannel: "beta")
        XCTAssertEqual(updater.channel, .beta)
        updater.setChannel(.stable)
        XCTAssertEqual(defaults.string(forKey: "updateChannel"), "stable")
        XCTAssertEqual(AppUpdater(defaults: defaults, bundledChannel: "beta").channel, .stable)
        updater.setChannel(.beta)
        XCTAssertEqual(AppUpdater(defaults: defaults, bundledChannel: "stable").channel, .beta)
    }

    func testCancelledRestartLeavesEveryVaultUnlocked() async {
        let first = await openedStore()
        let second = await openedStore()
        let firstSession = first.sessionID
        var decisions = 0
        XCTAssertFalse(VaultApplicationDelegate.prepareToTerminate(stores: [first, second]) { _ in
            decisions += 1
            return decisions == 1
        })
        XCTAssertEqual(decisions, 2)
        XCTAssertFalse(first.isLocked)
        XCTAssertFalse(second.isLocked)
        XCTAssertEqual(first.sessionID, firstSession)
        first.lock()
        second.lock()
    }

    func testConfirmedRestartLocksEveryVault() async {
        let first = await openedStore()
        let second = await openedStore()
        XCTAssertTrue(VaultApplicationDelegate.prepareToTerminate(stores: [first, second]) { _ in true })
        XCTAssertTrue(first.isLocked)
        XCTAssertTrue(second.isLocked)
        XCTAssertTrue(first.items.isEmpty)
        XCTAssertTrue(second.items.isEmpty)
    }

    func testBusyVaultCannotBeClosedByStaleApproval() async {
        let store = await openedStore()
        store.run(.updateEntry(MockVault.items[0]))
        XCTAssertTrue(store.isBusy)
        XCTAssertFalse(VaultApplicationDelegate.prepareToTerminate(stores: [store]) { _ in true })
        await store.waitForOperation()
        XCTAssertFalse(store.isLocked)
        store.lock()
    }

    func testCancelledRestartKeepsDirtyEdits() async {
        let repository = MemoryVaultRepository(vault: Vault(name: "Synthetic unsaved vault",
            groups: VaultGroup.sampleGroups, entries: MockVault.items, isDirty: true))
        let store = VaultStore()
        store.use(repository)
        store.unlock()
        await store.waitForUnlock()
        XCTAssertTrue(store.isDirty)
        XCTAssertFalse(VaultApplicationDelegate.prepareToTerminate(stores: [store]) { _ in false })
        XCTAssertTrue(store.isDirty)
        XCTAssertFalse(store.isLocked)
        XCTAssertFalse(store.items.isEmpty)
        store.lock()
    }

    func testRestartCannotDiscardDraftEvenIfAConfirmationIsStale() async {
        let store = await openedStore()
        store.addItem()
        XCTAssertTrue(store.hasDraft)
        XCTAssertFalse(VaultApplicationDelegate.prepareToTerminate(stores: [store]) { _ in true })
        XCTAssertFalse(store.isLocked)
        XCTAssertTrue(store.hasDraft)
        store.lock()
    }

    func testSessionReplacementDuringDialogCancelsRestart() async {
        let first = await openedStore()
        let second = await openedStore()
        XCTAssertFalse(VaultApplicationDelegate.prepareToTerminate(stores: [first, second]) { store in
            if store === second { first.use(MemoryVaultRepository()) }
            return true
        })
        XCTAssertFalse(second.isLocked)
        second.lock()
    }

    func testUpdateConfigurationRequiresAuthenticatedFeedAndArchive() throws {
        let bundle = Bundle(for: VaultStore.self)
        let info = try XCTUnwrap(bundle.infoDictionary)
        XCTAssertEqual(info["SUFeedURL"] as? String, "https://raw.githubusercontent.com/keelocker/keelocker/updates/appcast.xml")
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUSignedFeedFailureExpirationInterval"] as? Int, 0)
        XCTAssertEqual(info["SUAllowsAutomaticUpdates"] as? Bool, false)
        XCTAssertEqual(info["SUEnableSystemProfiling"] as? Bool, false)
    }

    private func openedStore() async -> VaultStore {
        let store = VaultStore()
        store.use(MemoryVaultRepository())
        store.unlock()
        await store.waitForUnlock()
        XCTAssertFalse(store.isLocked)
        return store
    }
}
