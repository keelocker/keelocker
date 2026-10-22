import Foundation
import Darwin

enum AttachmentExport {
    enum Failure: Error, Equatable {
        case protectedDestination, destinationExists

        var message: String {
            switch self {
            case .protectedDestination:
                "Choose a destination outside the vault and its recovery files."
            case .destinationExists:
                "Attachment export never replaces an existing file. Choose a new filename."
            }
        }
    }

    static func write(_ data: Data, to destination: URL, vaultURL: URL?, backupDirectory: URL?) throws {
        try Task.checkCancellation()
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let parent = canonical(destination.deletingLastPathComponent())
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw posixError() }
        defer { close(directory) }
        let name = destination.lastPathComponent
        try validate(name: name, directory: directory, vaultURL: vaultURL, backupDirectory: backupDirectory)

        // Stage private plaintext in the opened parent. linkat publishes only a
        // complete file and refuses every existing entry, including symlinks.
        let temporary = ".keelocker-export-\(UUID().uuidString)"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlinkat(directory, temporary, 0)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try Task.checkCancellation()
        // Recheck the actual opened parent in case a directory moved while
        // writing. Keep pathname resolution and all file work off the main actor.
        try validate(name: name, directory: directory, vaultURL: vaultURL, backupDirectory: backupDirectory)
        guard linkat(directory, temporary, directory, name, 0) == 0 else {
            if errno == EEXIST { throw Failure.destinationExists }
            throw posixError()
        }
    }

    private static func validate(name: String, directory: Int32, vaultURL: URL?, backupDirectory: URL?) throws {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(directory, F_GETPATH, &path) == 0 else { throw posixError() }
        let parent = canonical(URL(fileURLWithPath: String(cString: path), isDirectory: true))
        let destination = parent.appendingPathComponent(name).standardizedFileURL
        let caseSensitive = try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        let options: String.CompareOptions = caseSensitive == true ? [] : .caseInsensitive
        let defaultBackups = URL.applicationSupportDirectory.appending(path: "KeeLocker/Backups", directoryHint: .isDirectory)
        var roots = [backupDirectory ?? defaultBackups]
        if let vaultURL {
            let vault = canonical(vaultURL)
            let legacy = canonical(vaultURL.appendingPathExtension("bak"))
            guard destination.path.compare(vault.path, options: options) != .orderedSame,
                  destination.path.compare(legacy.path, options: options) != .orderedSame else {
                throw Failure.protectedDestination
            }
            roots.append(vault.deletingLastPathComponent().appendingPathComponent(".keelocker-backups", isDirectory: true))
        }
        guard !roots.contains(where: { contains(canonical($0), destination, options: options) }) else {
            throw Failure.protectedDestination
        }
    }

    private static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func contains(_ directory: URL, _ file: URL, options: String.CompareOptions) -> Bool {
        let prefix = directory.pathComponents
        let components = file.pathComponents
        return prefix.count <= components.count && zip(prefix, components).allSatisfy {
            $0.compare($1, options: options) == .orderedSame
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
