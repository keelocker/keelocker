import XCTest
import Darwin
@testable import KeeLocker

final class AttachmentExportTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let source: URL
        let backups: URL
        let original = Data("Synthetic vault bytes".utf8)
        let attachment = Data("Synthetic plaintext attachment".utf8)

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            source = directory.appendingPathComponent("synthetic.kdbx")
            backups = directory.appendingPathComponent("configured-backups")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try original.write(to: source)
        }

        func export(to destination: URL) throws {
            try AttachmentExport.write(attachment, to: destination, vaultURL: source, backupDirectory: backups)
        }
    }

    func testExistingVaultAndBackupFilesArePreserved() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let legacy = fixture.source.appendingPathExtension("bak")
        let original = fixture.backups.appendingPathComponent("namespace/original.kdbx")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture.original.write(to: legacy)
        try fixture.original.write(to: original)
        for destination in [fixture.source, legacy, original] {
            XCTAssertThrowsError(try fixture.export(to: destination))
            XCTAssertEqual(try Data(contentsOf: destination), fixture.original)
        }
    }

    func testExistingOrdinaryFileIsPreservedWithExplicitError() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let destination = fixture.directory.appendingPathComponent("existing.txt")
        try fixture.original.write(to: destination)
        XCTAssertThrowsError(try fixture.export(to: destination)) { error in
            XCTAssertEqual(error as? AttachmentExport.Failure, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), fixture.original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted(), ["existing.txt", "synthetic.kdbx"])
    }

    func testSymlinkAndHardlinkDestinationsArePreserved() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let symbolic = fixture.directory.appendingPathComponent("symbolic.txt")
        let hardlink = fixture.directory.appendingPathComponent("hardlink.txt")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: fixture.source)
        try FileManager.default.linkItem(at: fixture.source, to: hardlink)
        for destination in [symbolic, hardlink] {
            XCTAssertThrowsError(try fixture.export(to: destination))
            XCTAssertEqual(try Data(contentsOf: destination), fixture.original)
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symbolic.path), fixture.source.path)
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: fixture.source.path)
        let hardlinkAttributes = try FileManager.default.attributesOfItem(atPath: hardlink.path)
        XCTAssertEqual(sourceAttributes[.systemFileNumber] as? NSNumber, hardlinkAttributes[.systemFileNumber] as? NSNumber)
    }

    func testMissingVaultAndLegacyBackupPathsRemainProtected() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.removeItem(at: fixture.source)
        for destination in [fixture.source, fixture.source.appendingPathExtension("bak")] {
            XCTAssertThrowsError(try fixture.export(to: destination)) { error in
                XCTAssertEqual(error as? AttachmentExport.Failure, .protectedDestination)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testNewFilesInsideConfiguredAndFallbackBackupDirectoriesAreRefused() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for directory in [fixture.backups, fixture.directory.appendingPathComponent(".keelocker-backups")] {
            let namespace = directory.appendingPathComponent("namespace")
            try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
            let destination = namespace.appendingPathComponent("new.txt")
            XCTAssertThrowsError(try fixture.export(to: destination)) { error in
                XCTAssertEqual(error as? AttachmentExport.Failure, .protectedDestination)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testMissingVaultCaseAliasIsProtectedOnCaseInsensitiveVolumes() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let values = try fixture.directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard values.volumeSupportsCaseSensitiveNames != true else { throw XCTSkip("Case-sensitive volume") }
        try FileManager.default.removeItem(at: fixture.source)
        let alias = fixture.directory.appendingPathComponent("SYNTHETIC.KDBX")
        XCTAssertThrowsError(try fixture.export(to: alias)) { error in
            XCTAssertEqual(error as? AttachmentExport.Failure, .protectedDestination)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
    }

    func testBackupDirectoryAliasAndDanglingDestinationAreRefused() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.createDirectory(at: fixture.backups, withIntermediateDirectories: true)
        let alias = fixture.directory.appendingPathComponent("backup-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.backups)
        let destination = alias.appendingPathComponent("new.txt")
        XCTAssertThrowsError(try fixture.export(to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let dangling = fixture.directory.appendingPathComponent("dangling.txt")
        let missing = fixture.directory.appendingPathComponent("missing.txt")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: missing)
        XCTAssertThrowsError(try fixture.export(to: dangling))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path), missing.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testNewExportPreservesBytesAndHasPrivatePermissions() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let destination = fixture.directory.appendingPathComponent("new.txt")
        try fixture.export(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), fixture.attachment)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try fixture.export(to: destination))
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted(), ["new.txt", "synthetic.kdbx"])
    }

    func testEmptyAttachmentCanBeExported() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let destination = fixture.directory.appendingPathComponent("empty.txt")
        try AttachmentExport.write(Data(), to: destination, vaultURL: fixture.source, backupDirectory: fixture.backups)
        XCTAssertEqual(try Data(contentsOf: destination), Data())
    }

    func testUnrelatedNewKdbxFilenameIsAllowed() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let destination = fixture.directory.appendingPathComponent("unrelated-attachment.kdbx")
        try fixture.export(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), fixture.attachment)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
    }

    func testExportWithoutSourceAllowsNewFileButStillProtectsBackups() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let destination = fixture.directory.appendingPathComponent("memory-attachment.txt")
        try AttachmentExport.write(fixture.attachment, to: destination, vaultURL: nil, backupDirectory: fixture.backups)
        XCTAssertEqual(try Data(contentsOf: destination), fixture.attachment)
        try FileManager.default.createDirectory(at: fixture.backups, withIntermediateDirectories: true)
        let forbidden = fixture.backups.appendingPathComponent("new.txt")
        XCTAssertThrowsError(try AttachmentExport.write(fixture.attachment, to: forbidden, vaultURL: nil, backupDirectory: fixture.backups))
        XCTAssertFalse(FileManager.default.fileExists(atPath: forbidden.path))
    }
}
