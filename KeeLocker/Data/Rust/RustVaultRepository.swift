import Foundation
import Darwin

protocol RustVaultOpening: Sendable {
    func open(path: String, password: String, keyFile: String?) throws -> CoreVault
    func open(path: String, keyMaterial: Data) throws -> CoreVault
}

private struct NativeRustVaultOpening: RustVaultOpening {
    let backupDirectory: URL?

    func open(path: String, password: String, keyFile: String?) throws -> CoreVault {
        try configure(CoreVault.open(path: path, password: password, keyFile: keyFile))
    }
    func open(path: String, keyMaterial: Data) throws -> CoreVault {
        try configure(CoreVault.openWithKeyMaterial(path: path, material: keyMaterial))
    }

    private func configure(_ vault: CoreVault) throws -> CoreVault {
        do {
            if let backupDirectory { try vault.configureBackupDirectory(path: backupDirectory.path) }
            return vault
        } catch {
            vault.lock()
            throw error
        }
    }
}

// Only this adapter and generated bindings know the native Rust API.
@MainActor
final class RustVaultRepository: VaultRepository {
    nonisolated private static let favoriteTag = "KeeLocker:Favorite"
    let capabilities = VaultCapabilities.persistent
    let requiresPassword = true
    let supportsQuickUnlock = true
    let supportsRecovery = true
    private var url: URL
    private var session: CoreVault?
    private var generation = UUID()
    private let loadAdmission: VaultLoadAdmission
    private let opening: any RustVaultOpening
    private let backupDirectory: URL?
    private var loadRequest: VaultLoadAdmission.Request?
    private var selectionResolution: Task<URL, Never>?

    init(url: URL, loadAdmission: VaultLoadAdmission? = nil,
         opening: (any RustVaultOpening)? = nil, backupDirectory: URL? = nil) {
        self.url = url
        selectionResolution = Task.detached(priority: .userInitiated) { Self.canonicalSelection(url) }
        self.loadAdmission = loadAdmission ?? .shared
        self.opening = opening ?? NativeRustVaultOpening(backupDirectory: backupDirectory)
        self.backupDirectory = backupDirectory
    }

    func load(password: String, keyFile: URL?) async throws -> Vault {
        let opening = opening
        return try await load { path in
            try opening.open(path: path, password: password, keyFile: keyFile?.path)
        }
    }

    func load(keyMaterial: Data) async throws -> Vault {
        let opening = opening
        return try await load { path in
            try opening.open(path: path, keyMaterial: keyMaterial)
        }
    }

    func keyMaterial() async throws -> Data {
        guard let session else { throw VaultFailure.invalidOperation }
        let request = generation
        let material = try await Task.detached(priority: .userInitiated) { try session.keyMaterial() }.value
        guard !Task.isCancelled, generation == request else { throw CancellationError() }
        return material
    }

    func backups() async throws -> [VaultBackup] {
        try await resolveSelection()
        let request = generation
        let path = url.path
        let backupRoot = backupDirectory?.path
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let recovery = try CoreRecovery(path: path, backupDirectory: backupRoot)
                return try recovery.backups().map {
                    VaultBackup(id: $0.id, createdAt: $0.createdAt.map { Date(timeIntervalSince1970: Double($0)) },
                                size: $0.size, isOriginal: $0.isOriginal)
                }
            }.value
            guard !Task.isCancelled, request == generation else { throw CancellationError() }
            return result
        } catch { throw Self.failure(error) }
    }

    func restoreBackup(_ backup: VaultBackup, to destination: URL, password: String, keyFile: URL?) async throws -> VaultRecoveryResult {
        try await resolveSelection()
        let request = generation
        let path = url.path
        let backupRoot = backupDirectory?.path
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let recovery = try CoreRecovery(path: path, backupDirectory: backupRoot)
                let result = try recovery.restoreBackup(id: backup.id, destination: destination.path,
                                                        password: password, keyFile: keyFile?.path)
                return VaultRecoveryResult(url: URL(fileURLWithPath: result.path), directorySynced: result.directorySynced)
            }.value
            guard !Task.isCancelled, request == generation else { throw CancellationError() }
            return result
        } catch {
            if (error as? CoreError) == .Conflict { throw VaultFailure.destinationExists }
            throw Self.failure(error)
        }
    }

    private func load(_ open: @escaping @Sendable (String) throws -> CoreVault) async throws -> Vault {
        try Task.checkCancellation()
        try await resolveSelection()
        if let loadRequest { loadAdmission.cancel(loadRequest) }
        let request = UUID()
        generation = request
        let admission = loadAdmission.request(for: url)
        loadRequest = admission
        defer {
            loadAdmission.release(admission)
            if loadRequest == admission { loadRequest = nil }
        }
        do {
            try await loadAdmission.acquire(admission)
            guard !Task.isCancelled, generation == request else { throw CancellationError() }
            let opened = try await Task.detached(priority: .userInitiated) {
                try open(admission.path)
            }.value
            do {
                guard !Task.isCancelled, generation == request else { throw CancellationError() }
                let vault = try await snapshot(opened)
                guard !Task.isCancelled, generation == request else { throw CancellationError() }
                session = opened
                if let canonicalURL = vault.fileURL { url = canonicalURL }
                return vault
            } catch {
                // Keep admission until the late session has released its data.
                await Task.detached { opened.lock() }.value
                throw error
            }
        } catch {
            if generation == request { lock() }
            throw Self.failure(error)
        }
    }

    func lock() {
        generation = UUID()
        if let loadRequest { loadAdmission.cancel(loadRequest) }
        loadRequest = nil
        let closing = session
        session = nil
        // Rust's mutex serializes with an in-flight save. Closing never blocks AppKit.
        Task.detached { closing?.lock() }
    }

    private func resolveSelection() async throws {
        guard let resolution = selectionResolution else { return }
        let request = generation
        let resolved = await resolution.value
        guard !Task.isCancelled, request == generation else { throw CancellationError() }
        url = resolved
        selectionResolution = nil
    }

    nonisolated private static func canonicalSelection(_ selected: URL) -> URL {
        // Foundation deliberately abbreviates /private/var to /var even after
        // resolving symlinks. Recovery namespaces require the native realpath.
        // Resolve existing ancestors off the main thread, retaining a missing
        // vault/parent suffix so recovery still works after files are removed.
        var current = selected.absoluteURL
        var missing: [String] = []
        while true {
            let resolved: URL? = current.withUnsafeFileSystemRepresentation { path in
                guard let path, let canonical = realpath(path, nil) else { return nil }
                defer { free(canonical) }
                return URL(fileURLWithPath: String(cString: canonical))
            }
            if var resolved {
                for component in missing.reversed() { resolved.appendPathComponent(component) }
                return resolved
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return selected }
            missing.append(current.lastPathComponent)
            current = parent
        }
    }

    func execute(_ command: VaultCommand) async throws -> VaultCommandResult {
        guard let session else { throw VaultFailure.invalidOperation }
        let request = generation
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                var saveFailure: VaultFailure?
                switch command {
                case .createEntry(let item):
                    guard !item.isRedacted else { throw VaultFailure.invalidOperation }
                    _ = try session.createEntry(group: item.group.id.uuidString, edit: Self.edit(item))
                case .updateEntry(let item):
                    guard !item.isRedacted else { throw VaultFailure.invalidOperation }
                    try session.updateEntry(id: item.id.uuidString, edit: Self.edit(item))
                case .deleteEntry(let id): try session.deleteEntry(id: id.uuidString)
                case .restoreEntry(let id): try session.restoreEntry(id: id.uuidString)
                case .deleteEntryPermanently(let id): try session.deleteEntryPermanently(id: id.uuidString)
                case .moveEntry(let id, let destination): try session.moveEntry(id: id.uuidString, destination: destination.uuidString)
                case .createGroup(let parent, let name): _ = try session.createGroup(parent: parent.uuidString, name: name)
                case .renameGroup(let id, let name): try session.renameGroup(id: id.uuidString, name: name)
                case .deleteGroup(let id): try session.deleteGroup(id: id.uuidString)
                case .moveGroup(let id, let destination): try session.moveGroup(id: id.uuidString, destination: destination.uuidString)
                case .save:
                    do { try session.save() }
                    catch CoreError.WriteFailed { saveFailure = .writeFailed }
                case .reload: try session.reload()
                case .saveAs(let url):
                    do { try session.saveAs(path: url.path) }
                    catch CoreError.WriteFailed { saveFailure = .writeFailed }
                case .putAttachment(let id, let name, let data): try session.putAttachment(entry: id.uuidString, name: name, data: data)
                case .deleteAttachment(let id, let name): try session.deleteAttachment(entry: id.uuidString, name: name)
                }
                switch command {
                case .save, .saveAs, .reload:
                    break
                default:
                    do { try session.save() }
                    catch { saveFailure = (Self.failure(error) as? VaultFailure) ?? .writeFailed }
                }
                // WriteFailed can follow a committed rename. Rust's snapshot owns
                // the accepted path/hash and retains dirty until durability recovers.
                return VaultCommandResult(vault: try Self.map(session.snapshot()), saveFailure: saveFailure)
            }.value
            guard !Task.isCancelled, generation == request else { throw CancellationError() }
            if let url = result.vault.fileURL { self.url = url }
            return result
        } catch {
            if case .reload = command, (error as? CoreError) == .WrongCredentials {
                throw VaultFailure.credentialsChanged
            }
            if case .saveAs(let destination) = command,
               destination.standardizedFileURL != url.standardizedFileURL,
               (error as? CoreError) == .Conflict {
                throw VaultFailure.destinationExists
            }
            throw Self.failure(error)
        }
    }

    func refresh() async throws -> Vault? {
        guard let session else { throw VaultFailure.invalidOperation }
        let request = generation
        do {
            let vault = try await Task.detached(priority: .userInitiated) {
                guard try session.reloadIfChanged() else { return Optional<Vault>.none }
                return try Self.map(session.snapshot())
            }.value
            guard !Task.isCancelled, generation == request else { throw CancellationError() }
            return vault
        } catch {
            if (error as? CoreError) == .WrongCredentials { throw VaultFailure.credentialsChanged }
            throw Self.failure(error)
        }
    }

    func entry(_ id: UUID) async throws -> VaultEntry {
        guard let session else { throw VaultFailure.invalidOperation }
        let request = generation
        do {
            let result = try await Task.detached {
                let source = try session.inspectEntry(id: id.uuidString, includeHistory: false)
                return try Self.map(source.entry, groups: Self.groups(source.groups), icons: Self.iconIndex(Self.icons(source.customIcons)))
            }.value
            guard !Task.isCancelled, generation == request else { throw CancellationError() }
            return result
        } catch { throw Self.failure(error) }
    }

    func history(_ id: UUID) async throws -> [VaultEntry] {
        guard let session else { throw VaultFailure.invalidOperation }
        let request = generation
        do {
            let result = try await Task.detached {
                let source = try session.inspectEntry(id: id.uuidString, includeHistory: true)
                let groups = try Self.groups(source.groups)
                let icons = try Self.iconIndex(Self.icons(source.customIcons))
                return try source.history.map { try Self.map($0, groups: groups, icons: icons) }
            }.value
            guard !Task.isCancelled, generation == request else { throw CancellationError() }
            return result
        } catch { throw Self.failure(error) }
    }

    func attachment(_ id: UUID, name: String) async throws -> Data {
        guard let session else { throw VaultFailure.invalidOperation }
        do { return try await Task.detached { try session.attachment(entry: id.uuidString, name: name) }.value }
        catch { throw Self.failure(error) }
    }

    private func snapshot(_ session: CoreVault) async throws -> Vault {
        try await Task.detached { try Self.map(session.snapshot()) }.value
    }

    nonisolated private static func edit(_ item: VaultEntry) -> CoreEntryEdit {
        CoreEntryEdit(title: item.title, username: item.username, password: item.password,
                      url: item.website, notes: item.notes,
                      tags: item.tags.filter { $0 != favoriteTag } + (item.isFavorite ? [favoriteTag] : []),
                      customFields: item.customFields.map { CoreCustomField(name: $0.name, value: $0.value, protected: $0.isSensitive) },
                      icon: item.isIconModified ? iconEdit(item) : nil)
    }

    nonisolated private static func iconEdit(_ item: VaultEntry) -> CoreIconEdit? {
        switch item.icon {
        case .builtIn(let id): .builtIn(id: id)
        case .custom(let icon): .custom(id: icon.id.uuidString)
        case .imported(let icon):
            if let origin = item.websiteIconOrigin {
                .website(data: icon.data, name: icon.name, origin: origin.absoluteString)
            } else { .import(data: icon.data, name: icon.name) }
        case nil: nil
        }
    }

    nonisolated private static func groups(_ source: [CoreGroup]) throws -> [VaultGroup] {
        try source.map { g in
            guard let id = UUID(uuidString: g.id) else { throw VaultFailure.corruptedDatabase }
            return VaultGroup(id: id, name: g.name, parentID: g.parentId.flatMap(UUID.init(uuidString:)), path: g.path,
                              createdAt: g.createdAt.map { Date(timeIntervalSince1970: Double($0)) },
                              modifiedAt: g.modifiedAt.map { Date(timeIntervalSince1970: Double($0)) })
        }
    }

    nonisolated private static func icons(_ source: [CoreCustomIcon]) throws -> [VaultCustomIcon] {
        try source.map { icon in
            guard let id = UUID(uuidString: icon.id) else { throw VaultFailure.corruptedDatabase }
            return VaultCustomIcon(id: id, name: icon.name ?? "Custom icon", data: icon.data)
        }
    }

    nonisolated private static func map(_ source: CoreSnapshot) throws -> Vault {
        let groups = try groups(source.groups)
        let icons = try icons(source.customIcons)
        let index = iconIndex(icons)
        return try Vault(name: source.info.name, groups: groups,
                         entries: source.entries.map {
                             var summary = try map($0, groups: groups, icons: index)
                             summary.isRedacted = true
                             return summary
                         },
                         isDirty: source.info.dirty, fileURL: URL(fileURLWithPath: source.info.path), customIcons: icons,
                         recycleBinID: source.info.recycleBinId.flatMap(UUID.init(uuidString:)),
                         recycleBinEnabled: source.info.recycleBinEnabled)
    }

    nonisolated private static func iconIndex(_ icons: [VaultCustomIcon]) -> [UUID: VaultCustomIcon] {
        Dictionary(icons.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    nonisolated private static func map(_ e: CoreEntry, groups: [VaultGroup], icons: [UUID: VaultCustomIcon]) throws -> VaultEntry {
        guard let id = UUID(uuidString: e.id), let groupID = UUID(uuidString: e.groupId),
              let group = groups.first(where: { $0.id == groupID }) else { throw VaultFailure.corruptedDatabase }
        var result = VaultEntry(id: id, title: e.title, username: e.username, password: e.password,
                               website: e.url, notes: e.notes, tags: e.tags.filter { $0 != favoriteTag },
                               customFields: e.customFields.map { CustomField(name: $0.name, value: $0.value, isSensitive: $0.protected) },
                               oneTimePassword: e.otp.map { OneTimePassword(code: $0.code, period: Int(clamping: $0.period)) },
                               group: group, isFavorite: e.tags.contains(favoriteTag), iconName: "key.fill", iconColor: .indigo,
                               modifiedAt: e.modifiedAt.map { Date(timeIntervalSince1970: Double($0)) } ?? .distantPast,
                               createdAt: e.createdAt.map { Date(timeIntervalSince1970: Double($0)) })
        result.attachments = e.attachments.map { AttachmentMetadata(name: $0.name, size: $0.size) }
        result.historyCount = Int(clamping: e.historyCount)
        result.hasExplicitIcon = e.hasExplicitIcon
        switch e.icon {
        case .builtIn(let id): result.icon = .builtIn(id)
        case .custom(let id):
            guard let uuid = UUID(uuidString: id), let icon = icons[uuid] else { throw VaultFailure.corruptedDatabase }
            result.icon = .custom(icon)
        case nil: break
        }
        if let origin = e.websiteIconOrigin,
           let normalized = FaviconDownloader.origin(for: origin), normalized.absoluteString == origin {
            result.websiteIconOrigin = normalized
        }
        return result
    }

    nonisolated private static func failure(_ error: Error) -> Error {
        if let failure = error as? VaultFailure { return failure }
        guard let error = error as? CoreError else {
            return error is CancellationError ? error : VaultFailure.corruptedDatabase
        }
        switch error {
        case .WrongCredentials: return VaultFailure.wrongPassword
        case .UnsupportedDatabase: return VaultFailure.unsupportedDatabase
        case .CorruptedDatabase: return VaultFailure.corruptedDatabase
        case .ReadFailed: return VaultFailure.failedToReadFile
        case .WriteFailed: return VaultFailure.writeFailed
        case .Conflict: return VaultFailure.conflict
        case .InvalidOperation: return VaultFailure.invalidOperation
        }
    }
}

/// Admission covers open and snapshot/late-session cleanup, never saves or other
/// vaults. Shared state holds paths, IDs and continuations, not credential closures.
@MainActor
final class VaultLoadAdmission {
    static let shared = VaultLoadAdmission()

    struct Request: Equatable, Sendable {
        let path: String
        let id = UUID()
    }

    private struct Waiter {
        let request: Request
        let continuation: CheckedContinuation<Void, Error>
    }

    private var active: [String: UUID] = [:]
    private var queued: [String: Waiter] = [:]

    func request(for url: URL) -> Request {
        Request(path: url.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    func acquire(_ request: Request) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if active[request.path] == nil {
                    active[request.path] = request.id
                    continuation.resume()
                } else {
                    let previous = queued.updateValue(Waiter(request: request, continuation: continuation), forKey: request.path)
                    previous?.continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(request) }
        }
    }

    func cancel(_ request: Request) {
        guard queued[request.path]?.request == request else { return }
        queued.removeValue(forKey: request.path)?.continuation.resume(throwing: CancellationError())
        // An admitted synchronous open keeps its slot until it really finishes.
    }

    func release(_ request: Request) {
        guard active[request.path] == request.id else { return }
        if let next = queued.removeValue(forKey: request.path) {
            active[request.path] = next.request.id
            next.continuation.resume()
        } else {
            active.removeValue(forKey: request.path)
        }
    }

    // Read-only request metadata also permits deterministic admission tests.
    func queuedRequest(for url: URL) -> Request? {
        queued[url.resolvingSymlinksInPath().standardizedFileURL.path]?.request
    }
}
