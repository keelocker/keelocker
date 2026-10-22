import XCTest
@testable import KeeLocker

@MainActor
final class RecoveryTests: XCTestCase {
    func testRecoveryCapturesAliasIdentityBeforeUnlockAndRetainsItAfterFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("synthetic.kdbx")
        let alias = directory.appendingPathComponent("alias.kdbx")
        let decoy = directory.appendingPathComponent("decoy.kdbx")
        let root = directory.appendingPathComponent("backups")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/interop.kdbx")
        try FileManager.default.copyItem(at: fixture, to: source)
        try FileManager.default.copyItem(at: fixture, to: decoy)
        let original = try Data(contentsOf: source)
        let initial = RustVaultRepository(url: source, backupDirectory: root)
        let vault = try await initial.load(password: "fixture-password", keyFile: nil)
        var entry = try await initial.entry(XCTUnwrap(vault.entries.first?.id))
        entry.notes += "\nSynthetic save creates recovery copies"
        _ = try await initial.execute(.updateEntry(entry))
        initial.lock()
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        XCTAssertEqual(alias.resolvingSymlinksInPath().standardizedFileURL, source.resolvingSymlinksInPath().standardizedFileURL)
        let repository = RustVaultRepository(url: alias, backupDirectory: root)
        defer { repository.lock() }
        let copies: [VaultBackup]
        do { copies = try await repository.backups() }
        catch { XCTFail("Listing copies before unlock failed: \(error)"); return }
        let pinned = try XCTUnwrap(copies.first { $0.isOriginal })
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: decoy)
        try Data("Synthetic corrupted source".utf8).write(to: source, options: .atomic)
        do {
            _ = try await repository.load(password: "fixture-password", keyFile: nil)
            XCTFail("The captured source should fail to unlock after corruption")
        } catch { XCTAssertEqual(error as? VaultFailure, .unsupportedDatabase) }
        let afterFailure: [VaultBackup]
        do { afterFailure = try await repository.backups() }
        catch { XCTFail("Listing copies after failed unlock failed: \(error)"); return }
        XCTAssertEqual(afterFailure, copies)
        let destination = directory.appendingPathComponent("restored.kdbx")
        _ = try await repository.restoreBackup(pinned, to: destination, password: "fixture-password", keyFile: nil)
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testLockedRecoveryDoesNotUnlockOrChangeTheSelectedVault() async throws {
        let repository = SyntheticRecoveryRepository()
        let store = VaultStore()
        let source = URL(fileURLWithPath: "/tmp/synthetic-recovery-source.kdbx")
        store.use(repository, fileURL: source)
        XCTAssertTrue(store.supportsRecovery)
        let backups = try await store.backups()
        let destination = URL(fileURLWithPath: "/tmp/synthetic-recovered.kdbx")
        let recovered = try await store.restoreBackup(XCTUnwrap(backups.first), to: destination, password: "synthetic", keyFile: nil)
        XCTAssertEqual(recovered.url, destination)
        XCTAssertEqual(store.state, .locked)
        XCTAssertEqual(store.fileURL, source)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.isBusy)
    }

    func testReplacingSessionDiscardsLateRecoveryResults() async throws {
        let repository = SyntheticRecoveryRepository()
        let store = VaultStore()
        store.use(repository, fileURL: URL(fileURLWithPath: "/tmp/synthetic-old.kdbx"))
        repository.holdRestore = true
        let copies = try await store.backups()
        let backup = try XCTUnwrap(copies.first)
        let restoring = Task { try await store.restoreBackup(backup, to: URL(fileURLWithPath: "/tmp/synthetic-copy.kdbx"), password: "synthetic", keyFile: nil) }
        while repository.pendingRestore == nil { await Task.yield() }
        XCTAssertTrue(store.isBusy)
        store.use(SyntheticRecoveryRepository(), fileURL: URL(fileURLWithPath: "/tmp/synthetic-new.kdbx"))
        repository.finishRestore()
        do { _ = try await restoring.value; XCTFail("A revoked session returned a recovery result") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(store.fileURL?.lastPathComponent, "synthetic-new.kdbx")
        XCTAssertEqual(store.state, .locked)
        XCTAssertFalse(store.isBusy)
    }

    func testNativeRecoveryWorksAfterFailedUnlockAndKeepsDirtyEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("synthetic.kdbx")
        let root = directory.appendingPathComponent("backups")
        let recovered = directory.appendingPathComponent("recovered.kdbx")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/interop.kdbx")
        try FileManager.default.copyItem(at: fixture, to: source)
        let original = try Data(contentsOf: source)
        let store = VaultStore(backupDirectory: root)
        store.openFile(source)
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        var entry = try XCTUnwrap(store.selectedEntry)
        entry.notes += "\nSynthetic first saved edit"
        store.updateItem(entry)
        await store.waitForOperation()
        XCTAssertNil(store.operationFailure)
        let external = Data("Synthetic corrupted external source".utf8)
        try external.write(to: source, options: .atomic)
        entry.notes += "\nSynthetic unsaved edit"
        store.updateItem(entry)
        await store.waitForOperation()
        XCTAssertTrue(store.isDirty)
        let copies = try await store.backups()
        let backup = try XCTUnwrap(copies.first { $0.isOriginal })
        _ = try await store.restoreBackup(backup, to: recovered, password: "fixture-password", keyFile: nil)
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.selectedEntry?.notes, entry.notes)
        XCTAssertEqual(try Data(contentsOf: source), external)
        XCTAssertEqual(try Data(contentsOf: recovered), original)

        store.lock()
        store.unlock(password: "fixture-password")
        await store.waitForUnlock()
        XCTAssertNotEqual(store.state, .unlocked)
        let lockedCopies = try await store.backups()
        let lockedOriginal = try XCTUnwrap(lockedCopies.first { $0.isOriginal })
        let second = directory.appendingPathComponent("recovered-while-locked.kdbx")
        _ = try await store.restoreBackup(lockedOriginal, to: second, password: "fixture-password", keyFile: nil)
        XCTAssertEqual(try Data(contentsOf: second), original)
        XCTAssertNotEqual(store.state, .unlocked)
        store.lock()
    }
}

@MainActor
private final class SyntheticRecoveryRepository: VaultRepository {
    let capabilities = VaultCapabilities.persistent
    let requiresPassword = true
    let supportsRecovery = true
    var holdRestore = false
    var pendingRestore: CheckedContinuation<Void, Never>?
    func finishRestore() { pendingRestore?.resume(); pendingRestore = nil }
    func load(password: String, keyFile: URL?) async throws -> Vault { throw VaultFailure.wrongPassword }
    func execute(_ command: VaultCommand) async throws -> VaultCommandResult { throw VaultFailure.invalidOperation }
    func entry(_ id: UUID) async throws -> VaultEntry { throw VaultFailure.invalidOperation }
    func history(_ id: UUID) async throws -> [VaultEntry] { [] }
    func attachment(_ id: UUID, name: String) async throws -> Data { throw VaultFailure.invalidOperation }
    func backups() async throws -> [VaultBackup] { [VaultBackup(id: "synthetic-original", createdAt: nil, size: 123, isOriginal: true)] }
    func restoreBackup(_ backup: VaultBackup, to destination: URL, password: String, keyFile: URL?) async throws -> VaultRecoveryResult {
        if holdRestore { await withCheckedContinuation { pendingRestore = $0 } }
        return VaultRecoveryResult(url: destination, directorySynced: true)
    }
}
