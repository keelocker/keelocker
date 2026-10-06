import XCTest
@testable import KeeLocker

@MainActor
final class QuickUnlockTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/synthetic-quick-unlock.kdbx")
    private let material = Data(repeating: 42, count: 36)

    func testCacheSurvivesLockButCannotBeRecoveredByANewService() async throws {
        let storage = SyntheticKeyStorage()
        let service = SessionQuickUnlock(storage: storage)
        try await service.cache(material, for: url, request: UUID())
        let keys = await storage.keys()
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys.first?.count, 32)
        XCTAssertNotEqual(keys.first, material)
        let recovered = try await service.recover(for: url, request: UUID())
        XCTAssertEqual(recovered, material)
        let restarted = SessionQuickUnlock(storage: storage)
        XCTAssertFalse(restarted.contains(url))
        do {
            _ = try await restarted.recover(for: url, request: UUID())
            XCTFail("A new process has no cached ciphertext")
        } catch { XCTAssertEqual(error as? QuickUnlockFailure, .missingKey) }
        service.reset()
        XCTAssertFalse(service.contains(url))
    }

    func testNativeCancellationStateIsReleasedAtRequestCompletion() async throws {
        let storage = EnclaveQuickUnlockStorage()
        for _ in 0..<20 {
            let request = UUID()
            storage.cancel(request: request)
            storage.finishRequest(request)
            do {
                _ = try await storage.read(account: "missing-synthetic-account", request: request)
                XCTFail("No native record exists")
            } catch { XCTAssertEqual(error as? QuickUnlockFailure, .missingKey) }
        }
    }

    func testCacheIsScopedToTheCanonicalVaultPathAndDetectsTampering() async throws {
        let storage = SyntheticKeyStorage()
        let service = SessionQuickUnlock(storage: storage)
        try await service.cache(material, for: url, request: UUID())
        XCTAssertTrue(service.contains(URL(fileURLWithPath: "/tmp/subdirectory/../synthetic-quick-unlock.kdbx")))
        XCTAssertFalse(service.contains(URL(fileURLWithPath: "/tmp/other-vault.kdbx")))
        await storage.corruptKeys()
        do {
            _ = try await service.recover(for: url, request: UUID())
            XCTFail("AES-GCM must authenticate the cached material")
        } catch { XCTAssertEqual(error as? QuickUnlockFailure, .invalidMaterial) }
    }

    func testCancelledReadCannotReturnLateCredentials() async throws {
        let storage = SyntheticKeyStorage()
        let service = SessionQuickUnlock(storage: storage)
        try await service.cache(material, for: url, request: UUID())
        await storage.suspendNextRead()
        let request = UUID()
        let recovery = Task { try await service.recover(for: url, request: request) }
        while !(await storage.readIsWaiting()) { await Task.yield() }
        service.cancel(request: request)
        await storage.resumeRead()
        do { _ = try await recovery.value; XCTFail("Cancelled read returned credentials") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(service.contains(url))
        let recovered = try await service.recover(for: url, request: UUID())
        XCTAssertEqual(recovered, material)
    }

    func testForgettingDuringEnrollmentCannotRestoreACache() async throws {
        let storage = SyntheticKeyStorage()
        let service = SessionQuickUnlock(storage: storage)
        await storage.suspendNextWrite()
        let enrollment = Task { try await service.cache(material, for: url, request: UUID()) }
        while !(await storage.writeIsWaiting()) { await Task.yield() }
        service.forget(url)
        await storage.resumeWrite()
        do { try await enrollment.value; XCTFail("Late enrollment restored a disabled cache") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(service.contains(url))
    }

    func testPasswordUnlockEnrollsByDefaultAndTouchIDReopensAfterLock() async throws {
        let storage = SyntheticKeyStorage()
        let service = SessionQuickUnlock(storage: storage)
        let repository = SyntheticQuickRepository(material: material)
        let store = VaultStore(quickUnlock: service)
        store.use(repository, fileURL: url)
        store.unlock(password: "synthetic-password")
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .unlocked)
        XCTAssertTrue(store.canQuickUnlock)
        store.lock()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.selectedEntry)
        store.unlockWithTouchID()
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .unlocked)
        XCTAssertEqual(repository.materialLoads, 1)
        store.lock()
        store.forgetQuickUnlock()
        XCTAssertFalse(store.canQuickUnlock)
        store.unlock(password: "synthetic-password")
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .unlocked)
    }

    func testEnrollmentFailureStillOpensWithPasswordAndDemoHasNoTouchID() async throws {
        let storage = SyntheticKeyStorage()
        await storage.rejectWrites()
        let service = SessionQuickUnlock(storage: storage)
        let store = VaultStore(quickUnlock: service)
        store.use(SyntheticQuickRepository(material: material), fileURL: url)
        store.unlock(password: "synthetic-password")
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .unlocked)
        XCTAssertEqual(store.quickUnlockFailure, .storageFailed)
        XCTAssertFalse(store.canQuickUnlock)
        store.openDemo()
        await store.waitForUnlock()
        XCTAssertFalse(store.canEnableTouchID)
        XCTAssertFalse(store.canQuickUnlock)
    }

    func testUnavailableTouchIDSkipsEnrollmentAndOpensWithPassword() async throws {
        let storage = SyntheticKeyStorage(available: false)
        let service = SessionQuickUnlock(storage: storage)
        let repository = SyntheticQuickRepository(material: material)
        let store = VaultStore(quickUnlock: service)
        store.use(repository, fileURL: url)
        store.unlock(password: "synthetic-password")
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .unlocked)
        XCTAssertNil(store.quickUnlockFailure)
        XCTAssertFalse(store.canQuickUnlock)
        XCTAssertFalse(service.contains(url))
        XCTAssertEqual(repository.materialExports, 0)
        let keys = await storage.keys()
        XCTAssertTrue(keys.isEmpty)
    }

    func testWrongPasswordNeverEnrollsTouchID() async throws {
        let storage = SyntheticKeyStorage()
        let service = SessionQuickUnlock(storage: storage)
        let repository = SyntheticQuickRepository(material: material)
        repository.rejectPassword = true
        let store = VaultStore(quickUnlock: service)
        store.use(repository, fileURL: url)
        store.unlock(password: "wrong-synthetic-password")
        await store.waitForUnlock()
        XCTAssertEqual(store.failure, .wrongPassword)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(service.contains(url))
        XCTAssertEqual(repository.materialExports, 0)
        let keys = await storage.keys()
        XCTAssertTrue(keys.isEmpty)
    }

    func testCancelledAutomaticEnrollmentStillUnlocksWithPassword() async throws {
        let storage = SyntheticKeyStorage()
        await storage.rejectWrites(.cancelled)
        let service = SessionQuickUnlock(storage: storage)
        let store = VaultStore(quickUnlock: service)
        store.use(SyntheticQuickRepository(material: material), fileURL: url)
        store.unlock(password: "synthetic-password")
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .unlocked)
        XCTAssertEqual(store.quickUnlockFailure, .cancelled)
        XCTAssertFalse(store.canQuickUnlock)
        XCTAssertFalse(service.contains(url))
    }

    func testLockAndVaultSwitchDiscardALateBiometricResult() async throws {
        let storage = SyntheticKeyStorage()
        let service = SessionQuickUnlock(storage: storage)
        let first = SyntheticQuickRepository(material: material)
        let store = VaultStore(quickUnlock: service)
        store.use(first, fileURL: url)
        store.unlock(password: "synthetic-password")
        await store.waitForUnlock()
        store.lock()
        await storage.suspendNextRead()
        store.unlockWithTouchID()
        while !(await storage.readIsWaiting()) { await Task.yield() }
        let second = SyntheticQuickRepository(material: material)
        store.use(second, fileURL: URL(fileURLWithPath: "/tmp/replacement-quick-unlock.kdbx"))
        await storage.resumeRead()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.state, .locked)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(first.materialLoads, 0)
        XCTAssertEqual(second.materialLoads, 0)
        XCTAssertFalse(store.canQuickUnlock)
    }

    func testLockDuringEnrollmentDropsLateCacheAndPlaintext() async throws {
        let storage = SyntheticKeyStorage()
        let service = SessionQuickUnlock(storage: storage)
        let store = VaultStore(quickUnlock: service)
        store.use(SyntheticQuickRepository(material: material), fileURL: url)
        await storage.suspendNextWrite()
        store.unlock(password: "synthetic-password")
        while !(await storage.writeIsWaiting()) { await Task.yield() }
        store.lock()
        await storage.resumeWrite()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.state, .locked)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(service.contains(url))
    }

    func testChangedCredentialsInvalidateQuickUnlockAndKeepPasswordFallback() async throws {
        let service = SessionQuickUnlock(storage: SyntheticKeyStorage())
        let repository = SyntheticQuickRepository(material: material)
        let store = VaultStore(quickUnlock: service)
        store.use(repository, fileURL: url)
        store.unlock(password: "synthetic-password")
        await store.waitForUnlock()
        store.lock()
        repository.rejectMaterial = true
        store.unlockWithTouchID()
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .locked)
        XCTAssertFalse(store.canQuickUnlock)
        XCTAssertEqual(store.quickUnlockFailure, .invalidMaterial)
        store.unlock(password: "synthetic-new-password")
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .unlocked)
    }

    func testBiometricCancellationKeepsVaultLockedAndPasswordUsable() async throws {
        let storage = SyntheticKeyStorage()
        let service = SessionQuickUnlock(storage: storage)
        let store = VaultStore(quickUnlock: service)
        store.use(SyntheticQuickRepository(material: material), fileURL: url)
        store.unlock(password: "synthetic-password")
        await store.waitForUnlock()
        store.lock()
        await storage.rejectNextRead(.cancelled)
        store.unlockWithTouchID()
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .locked)
        XCTAssertEqual(store.quickUnlockFailure, .cancelled)
        XCTAssertTrue(store.canQuickUnlock)
        XCTAssertTrue(store.items.isEmpty)
        store.unlock(password: "synthetic-password")
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .unlocked)
    }

    func testLateDatabaseOpenAfterBiometricsCannotReopenLockedStore() async throws {
        let service = SessionQuickUnlock(storage: SyntheticKeyStorage())
        let repository = SyntheticQuickRepository(material: material)
        let store = VaultStore(quickUnlock: service)
        store.use(repository, fileURL: url)
        store.unlock(password: "synthetic-password")
        await store.waitForUnlock()
        store.lock()
        repository.pauseMaterialLoad = true
        store.unlockWithTouchID()
        while repository.loading == nil { await Task.yield() }
        store.lock()
        repository.resumeLoad()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.state, .locked)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.selectedEntry)
    }

    func testCancelledRecoveryCannotForgetAnotherWindowsNewRegistration() async throws {
        let storage = SyntheticKeyStorage()
        let service = SessionQuickUnlock(storage: storage)
        let first = VaultStore(quickUnlock: service)
        first.use(SyntheticQuickRepository(material: material), fileURL: url)
        first.unlock(password: "synthetic-password")
        await first.waitForUnlock()
        first.lock()
        await storage.suspendNextRead()
        first.unlockWithTouchID()
        while !(await storage.readIsWaiting()) { await Task.yield() }

        let secondRepository = SyntheticQuickRepository(material: material)
        let second = VaultStore(quickUnlock: service)
        second.use(secondRepository, fileURL: url)
        second.unlock(password: "synthetic-password")
        await second.waitForUnlock()
        XCTAssertTrue(service.contains(url))
        await storage.resumeRead()
        await first.waitForUnlock()
        XCTAssertEqual(first.state, .locked)
        XCTAssertEqual(first.quickUnlockFailure, .cancelled)
        XCTAssertTrue(service.contains(url), "The obsolete recovery must preserve the new registration")
        second.lock()
        second.unlockWithTouchID()
        await second.waitForUnlock()
        XCTAssertEqual(second.state, .unlocked)
        XCTAssertEqual(secondRepository.materialLoads, 1)
    }

    func testOldSessionCredentialFailuresPreserveNewerRegistration() async throws {
        for reload in [false, true] {
            let service = SessionQuickUnlock(storage: SyntheticKeyStorage())
            let oldRepository = SyntheticQuickRepository(material: material)
            let first = VaultStore(quickUnlock: service)
            first.use(oldRepository, fileURL: url)
            first.unlock(password: "synthetic-old-password")
            await first.waitForUnlock()
            let second = VaultStore(quickUnlock: service)
            second.use(SyntheticQuickRepository(material: material), fileURL: url)
            second.unlock(password: "synthetic-current-password")
            await second.waitForUnlock()
            oldRepository.credentialsChanged = true
            if reload {
                first.run(.reload)
                await first.waitForOperation()
            } else {
                first.refreshFromDisk()
                await first.waitForRefresh()
            }
            XCTAssertEqual(first.operationFailure, .credentialsChanged)
            XCTAssertTrue(service.contains(url), "Old refresh/reload must preserve the replacement registration")
            second.lock()
            second.unlockWithTouchID()
            await second.waitForUnlock()
            XCTAssertEqual(second.state, .unlocked)
        }
    }

    func testObsoleteKeyExportCannotReplaceNewerEnrollment() async throws {
        let service = SessionQuickUnlock(storage: SyntheticKeyStorage())
        let oldRepository = SyntheticQuickRepository(material: material)
        oldRepository.pauseMaterialExport = true
        let first = VaultStore(quickUnlock: service)
        first.use(oldRepository, fileURL: url)
        first.unlock(password: "synthetic-old-password")
        while oldRepository.exporting == nil { await Task.yield() }
        let currentRepository = SyntheticQuickRepository(material: Data(repeating: 43, count: 36))
        let second = VaultStore(quickUnlock: service)
        second.use(currentRepository, fileURL: url)
        second.unlock(password: "synthetic-current-password")
        await second.waitForUnlock()
        oldRepository.resumeExport()
        await first.waitForUnlock()
        XCTAssertEqual(first.state, .unlocked, "Its completed password unlock remains usable")
        second.lock()
        second.unlockWithTouchID()
        await second.waitForUnlock()
        XCTAssertEqual(second.state, .unlocked, "The stale export must not overwrite current credentials")
        XCTAssertEqual(currentRepository.materialLoads, 1)
    }

    func testLateWrongCredentialsCannotForgetReplacementRegistration() async throws {
        let service = SessionQuickUnlock(storage: SyntheticKeyStorage())
        let oldRepository = SyntheticQuickRepository(material: material)
        let first = VaultStore(quickUnlock: service)
        first.use(oldRepository, fileURL: url)
        first.unlock(password: "synthetic-password")
        await first.waitForUnlock()
        first.lock()
        oldRepository.pauseMaterialLoad = true
        first.unlockWithTouchID()
        while oldRepository.loading == nil { await Task.yield() }
        let second = VaultStore(quickUnlock: service)
        second.use(SyntheticQuickRepository(material: material), fileURL: url)
        second.unlock(password: "synthetic-new-password")
        await second.waitForUnlock()
        oldRepository.rejectMaterial = true
        oldRepository.resumeLoad()
        await first.waitForUnlock()
        XCTAssertEqual(first.state, .locked)
        XCTAssertTrue(service.contains(url), "A stale KDBX failure must not delete the new registration")
        second.lock()
        second.unlockWithTouchID()
        await second.waitForUnlock()
        XCTAssertEqual(second.state, .unlocked)
    }

    func testDelayedPasswordOpenCannotReplaceNewerEnrollment() async throws {
        let service = SessionQuickUnlock(storage: SyntheticKeyStorage())
        let oldRepository = SyntheticQuickRepository(material: material)
        oldRepository.pausePasswordLoad = true
        let first = VaultStore(quickUnlock: service)
        first.use(oldRepository, fileURL: url)
        first.unlock(password: "synthetic-old-password")
        while oldRepository.passwordLoading == nil { await Task.yield() }
        let currentRepository = SyntheticQuickRepository(material: Data(repeating: 43, count: 36))
        let second = VaultStore(quickUnlock: service)
        second.use(currentRepository, fileURL: url)
        second.unlock(password: "synthetic-current-password")
        await second.waitForUnlock()
        oldRepository.resumePasswordLoad()
        await first.waitForUnlock()
        XCTAssertEqual(first.state, .unlocked)
        second.lock()
        second.unlockWithTouchID()
        await second.waitForUnlock()
        XCTAssertEqual(second.state, .unlocked, "Late password results cannot replace newer credentials")
    }

    func testRegistrationRevokedDuringDatabaseOpenCannotPublishVault() async throws {
        let service = SessionQuickUnlock(storage: SyntheticKeyStorage())
        let repository = SyntheticQuickRepository(material: material)
        let store = VaultStore(quickUnlock: service)
        store.use(repository, fileURL: url)
        store.unlock(password: "synthetic-password")
        await store.waitForUnlock()
        store.lock()
        let previousLocks = repository.locks
        repository.pauseMaterialLoad = true
        store.unlockWithTouchID()
        while repository.loading == nil { await Task.yield() }
        service.forget(url)
        repository.resumeLoad()
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .locked)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(repository.locks, previousLocks + 1, "The rejected repository session must be closed")
    }

    func testRetargetedCanonicalPathRestoredBeforeCallbackCannotPublishOtherVault() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.kdbx")
        let second = directory.appendingPathComponent("second.kdbx")
        let parked = directory.appendingPathComponent("parked.kdbx")
        try Data("synthetic first vault".utf8).write(to: first)
        try Data("synthetic second vault with the same keys".utf8).write(to: second)
        let service = SessionQuickUnlock(storage: SyntheticKeyStorage())
        let repository = SyntheticQuickRepository(material: material)
        repository.openedURL = first
        let store = VaultStore(quickUnlock: service)
        store.use(repository, fileURL: first)
        store.unlock(password: "synthetic-password")
        await store.waitForUnlock()
        store.lock()
        let previousLocks = repository.locks
        repository.pauseMaterialLoad = true
        // This hook runs after recovery, at the repository's canonical open boundary.
        repository.onMaterialLoad = {
            try FileManager.default.moveItem(at: first, to: parked)
            try FileManager.default.createSymbolicLink(at: first, withDestinationURL: second)
        }
        store.unlockWithTouchID()
        while repository.loading == nil, store.state == .unlocking { await Task.yield() }
        _ = try XCTUnwrap(repository.loading, "The canonical open must reach the delayed return gate")
        try FileManager.default.removeItem(at: first)
        try FileManager.default.moveItem(at: parked, to: first)
        XCTAssertNotNil(service.registration(for: first), "Resolving the original URL again hides the retarget")
        repository.resumeLoad()
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .locked)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.selectedEntry)
        XCTAssertEqual(repository.locks, previousLocks + 1, "Close the mismatched opened session")
        XCTAssertEqual(store.quickUnlockFailure, .missingKey)
    }

    func testCredentialChangeDuringEnrollmentIsDetectedByInitialRefresh() async throws {
        let storage = SyntheticKeyStorage()
        let service = SessionQuickUnlock(storage: storage)
        let repository = SyntheticQuickRepository(material: material)
        let store = VaultStore(quickUnlock: service)
        store.use(repository, fileURL: url)
        await storage.suspendNextWrite()
        store.unlock(password: "synthetic-password")
        while !(await storage.writeIsWaiting()) { await Task.yield() }
        repository.credentialsChanged = true
        await storage.resumeWrite()
        await store.waitForUnlock()
        await store.waitForRefresh()
        XCTAssertEqual(store.state, .unlocked, "Keep the successful password session available")
        XCTAssertEqual(store.operationFailure, .credentialsChanged)
        XCTAssertFalse(service.contains(url), "Invalidate the enrollment for the obsolete credentials")
        XCTAssertGreaterThan(repository.refreshes, 0)
        store.lock()
    }

    func testInitialRefreshAfterEnrollmentDefersForDraftThenAdoptsChange() async throws {
        let storage = SyntheticKeyStorage()
        let service = SessionQuickUnlock(storage: storage)
        let repository = SyntheticQuickRepository(material: material)
        let store = VaultStore(quickUnlock: service)
        store.use(repository, fileURL: url)
        await storage.suspendNextWrite()
        store.unlock(password: "synthetic-password")
        while !(await storage.writeIsWaiting()) { await Task.yield() }
        try await repository.changeExternalTitle("Changed while enrollment was waiting")
        store.hasDraft = true
        await storage.resumeWrite()
        await store.waitForUnlock()
        await store.waitForRefresh()
        XCTAssertEqual(repository.refreshes, 0)
        XCTAssertFalse(store.items.contains { $0.title == "Changed while enrollment was waiting" })
        store.hasDraft = false
        await store.waitForRefresh()
        XCTAssertEqual(repository.refreshes, 1)
        XCTAssertTrue(store.items.contains { $0.title == "Changed while enrollment was waiting" })
        XCTAssertEqual(store.selectedEntry?.title, "Changed while enrollment was waiting")
        XCTAssertFalse(store.isBusy)
        store.lock()
    }

    func testCredentialFailuresInvalidateTheOwningRegistration() async throws {
        for reload in [false, true] {
            let service = SessionQuickUnlock(storage: SyntheticKeyStorage())
            let repository = SyntheticQuickRepository(material: material)
            let store = VaultStore(quickUnlock: service)
            store.use(repository, fileURL: url)
            store.unlock(password: "synthetic-password")
            await store.waitForUnlock()
            repository.credentialsChanged = true
            if reload {
                store.run(.reload)
                await store.waitForOperation()
            } else {
                store.refreshFromDisk()
                await store.waitForRefresh()
            }
            XCTAssertEqual(store.operationFailure, .credentialsChanged)
            XCTAssertFalse(service.contains(url))
        }
    }

    func testBiometricReopenKeepsCanonicalVaultAfterSymlinkRetargeting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let first = directory.appendingPathComponent("first.kdbx")
        let second = directory.appendingPathComponent("second.kdbx")
        let link = directory.appendingPathComponent("vault-link.kdbx")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("interop.kdbx"), to: first)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("Matrix/xc-41-argon2id-chacha20.kdbx"), to: second)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let store = VaultStore(quickUnlock: SessionQuickUnlock(storage: SyntheticKeyStorage()))
        store.openFile(link)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        let canonical = first.resolvingSymlinksInPath().standardizedFileURL
        XCTAssertEqual(store.fileURL?.resolvingSymlinksInPath().standardizedFileURL, canonical)
        store.lock()
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        store.unlockWithTouchID()
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .unlocked)
        XCTAssertEqual(store.fileURL?.resolvingSymlinksInPath().standardizedFileURL, canonical,
                       "Reopen must target the enrolled canonical vault")
        store.lock()
    }

    func testRustBridgeQuickUnlockIncludesKeyFileAndCanSaveNormally() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Matrix")
        let copy = directory.appendingPathComponent("quick.kdbx")
        let keyFile = directory.appendingPathComponent("test.key")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("xc-41-argon2id-chacha20-key.kdbx"), to: copy)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("test.key"), to: keyFile)
        let service = SessionQuickUnlock(storage: SyntheticKeyStorage())
        let store = VaultStore(quickUnlock: service)
        store.openFile(copy)
        store.unlock(password: "fixture-password", keyFile: keyFile)
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .unlocked)
        let before = try XCTUnwrap(store.selectedEntry)
        store.lock()
        try FileManager.default.removeItem(at: keyFile)
        store.unlockWithTouchID()
        await store.waitForUnlock()
        XCTAssertEqual(store.state, .unlocked)
        XCTAssertEqual(store.selectedEntry?.password, before.password)
        var edited = try XCTUnwrap(store.selectedEntry)
        edited.title = "Saved after Quick Unlock"
        store.updateItem(edited)
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        let moved = directory.appendingPathComponent("save-as.kdbx")
        store.run(.saveAs(moved))
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        XCTAssertFalse(store.canQuickUnlock, "Save As requires a password unlock to enroll the destination path")
        store.lock()
        let reopened = RustVaultRepository(url: copy)
        _ = try await reopened.load(password: "fixture-password", keyFile: fixtures.appendingPathComponent("test.key"))
        let saved = try await reopened.entry(edited.id)
        XCTAssertEqual(saved.title, edited.title)
        XCTAssertEqual(saved.password, before.password)
        reopened.lock()
    }
}

/// Synthetic fixtures only. Intentionally ignores cancellation to exercise late native results.
private actor SyntheticKeyStorage: QuickUnlockKeyStorage {
    nonisolated private let available: Bool
    private var values: [String: Data] = [:]
    private var writeFailure: QuickUnlockFailure?
    private var readFailure: QuickUnlockFailure?
    private var pauseWrite = false
    private var pauseRead = false
    private var writing: CheckedContinuation<Void, Never>?
    private var reading: CheckedContinuation<Void, Never>?
    init(available: Bool = true) { self.available = available }
    nonisolated func isAvailable() -> Bool { available }
    nonisolated func cancel(request: UUID) {}
    func store(_ key: Data, account: String, request: UUID) async throws {
        if let failure = writeFailure { throw failure }
        if pauseWrite {
            pauseWrite = false
            await withCheckedContinuation { writing = $0 }
        }
        values[account] = key
    }
    func read(account: String, request: UUID) async throws -> Data {
        if let failure = readFailure { readFailure = nil; throw failure }
        let result = values[account]
        if pauseRead {
            pauseRead = false
            await withCheckedContinuation { reading = $0 }
        }
        guard let result else { throw QuickUnlockFailure.missingKey }
        return result
    }
    func delete(account: String) async throws { values.removeValue(forKey: account) }
    func keys() -> [Data] { Array(values.values) }
    func corruptKeys() { for account in Array(values.keys) { values[account] = Data(repeating: 0, count: 32) } }
    func rejectWrites(_ failure: QuickUnlockFailure = .storageFailed) { writeFailure = failure }
    func rejectNextRead(_ failure: QuickUnlockFailure) { readFailure = failure }
    func suspendNextWrite() { pauseWrite = true }
    func suspendNextRead() { pauseRead = true }
    func writeIsWaiting() -> Bool { writing != nil }
    func readIsWaiting() -> Bool { reading != nil }
    func resumeWrite() { writing?.resume(); writing = nil }
    func resumeRead() { reading?.resume(); reading = nil }
}

@MainActor
private final class SyntheticQuickRepository: VaultRepository {
    let capabilities = VaultCapabilities.persistent
    let requiresPassword = true
    let supportsQuickUnlock = true
    var materialLoads = 0
    var materialExports = 0
    var rejectPassword = false
    var rejectMaterial = false
    var credentialsChanged = false
    var pauseMaterialLoad = false
    var pauseMaterialExport = false
    var pausePasswordLoad = false
    var locks = 0
    var refreshes = 0
    var openedURL = URL(fileURLWithPath: "/tmp/synthetic-quick-unlock.kdbx")
    var onMaterialLoad: (() throws -> Void)?
    var loading: CheckedContinuation<Void, Never>?
    var exporting: CheckedContinuation<Data, Never>?
    var passwordLoading: CheckedContinuation<Vault, Never>?
    private let material: Data
    private let memory = MemoryVaultRepository()
    private var externalChange = false
    private var openedVault: Vault {
        var vault = memory.vault
        vault.fileURL = openedURL.resolvingSymlinksInPath().standardizedFileURL
        return vault
    }
    init(material: Data) { self.material = material }
    func load(password: String, keyFile: URL?) async throws -> Vault {
        guard !rejectPassword else { throw VaultFailure.wrongPassword }
        if pausePasswordLoad { return await withCheckedContinuation { passwordLoading = $0 } }
        return openedVault
    }
    func load(keyMaterial: Data) async throws -> Vault {
        materialLoads += 1
        guard keyMaterial == material, !rejectMaterial else { throw VaultFailure.wrongPassword }
        try onMaterialLoad?()
        let vault = openedVault
        if pauseMaterialLoad {
            await withCheckedContinuation { loading = $0 }
            guard !rejectMaterial else { throw VaultFailure.wrongPassword }
        }
        return vault
    }
    func resumeLoad() { loading?.resume(); loading = nil }
    func resumePasswordLoad() { passwordLoading?.resume(returning: openedVault); passwordLoading = nil }
    func lock() { locks += 1 }
    func keyMaterial() async throws -> Data {
        materialExports += 1
        if pauseMaterialExport { return await withCheckedContinuation { exporting = $0 } }
        return material
    }
    func resumeExport() { exporting?.resume(returning: material); exporting = nil }
    func entry(_ id: UUID) async throws -> VaultEntry { try await memory.entry(id) }
    func refresh() async throws -> Vault? {
        refreshes += 1
        if credentialsChanged { throw VaultFailure.credentialsChanged }
        guard externalChange else { return nil }
        externalChange = false
        return openedVault
    }
    func changeExternalTitle(_ title: String) async throws {
        var entry = memory.vault.entries[0]
        entry.title = title
        _ = try await memory.execute(.updateEntry(entry))
        externalChange = true
    }
    func execute(_ command: VaultCommand) async throws -> VaultCommandResult {
        if case .reload = command, credentialsChanged { throw VaultFailure.credentialsChanged }
        return try await memory.execute(command)
    }
}
