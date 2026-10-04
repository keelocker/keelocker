import Foundation

// Only this adapter and generated bindings know the native Rust API.
@MainActor
final class RustVaultRepository: VaultRepository {
    nonisolated private static let favoriteTag = "KeeLocker:Favorite"
    let capabilities = VaultCapabilities.persistent
    let requiresPassword = true
    let supportsQuickUnlock = true
    private var url: URL
    private var session: CoreVault?
    private var knownGroups: [VaultGroup] = []
    private var generation = UUID()

    init(url: URL) { self.url = url }

    func load(password: String, keyFile: URL?) async throws -> Vault {
        let path = url.path
        return try await load {
            try CoreVault.open(path: path, password: password, keyFile: keyFile?.path)
        }
    }

    func load(keyMaterial: Data) async throws -> Vault {
        let path = url.path
        return try await load {
            try CoreVault.openWithKeyMaterial(path: path, material: keyMaterial)
        }
    }

    func keyMaterial() async throws -> Data {
        guard let session else { throw VaultFailure.invalidOperation }
        let request = generation
        let material = try await Task.detached(priority: .userInitiated) { try session.keyMaterial() }.value
        guard !Task.isCancelled, generation == request else { throw CancellationError() }
        return material
    }

    private func load(_ open: @escaping @Sendable () throws -> CoreVault) async throws -> Vault {
        let request = UUID()
        generation = request
        do {
            let opened = try await Task.detached(priority: .userInitiated, operation: open).value
            guard !Task.isCancelled, generation == request else {
                opened.lock()
                throw CancellationError()
            }
            session = opened
            let vault = try await snapshot(opened)
            guard !Task.isCancelled, generation == request else { opened.lock(); throw CancellationError() }
            knownGroups = vault.groups
            if let canonicalURL = vault.fileURL { url = canonicalURL }
            return vault
        } catch {
            if generation == request { lock() }
            throw Self.failure(error)
        }
    }

    func lock() {
        generation = UUID()
        let closing = session
        session = nil
        knownGroups = []
        // Rust's mutex serializes with an in-flight save. Closing never blocks AppKit.
        Task.detached { closing?.lock() }
    }

    func execute(_ command: VaultCommand) async throws -> VaultCommandResult {
        guard let session else { throw VaultFailure.invalidOperation }
        let request = generation
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                switch command {
                case .createEntry(let item):
                    guard !item.isRedacted else { throw VaultFailure.invalidOperation }
                    _ = try session.createEntry(group: item.group.id.uuidString, edit: Self.edit(item))
                case .updateEntry(let item):
                    guard !item.isRedacted else { throw VaultFailure.invalidOperation }
                    try session.updateEntry(id: item.id.uuidString, edit: Self.edit(item))
                case .deleteEntry(let id): try session.deleteEntry(id: id.uuidString)
                case .moveEntry(let id, let destination): try session.moveEntry(id: id.uuidString, destination: destination.uuidString)
                case .createGroup(let parent, let name): _ = try session.createGroup(parent: parent.uuidString, name: name)
                case .renameGroup(let id, let name): try session.renameGroup(id: id.uuidString, name: name)
                case .deleteGroup(let id): try session.deleteGroup(id: id.uuidString)
                case .moveGroup(let id, let destination): try session.moveGroup(id: id.uuidString, destination: destination.uuidString)
                case .save: try session.save()
                case .reload: try session.reload()
                case .saveAs(let url): try session.saveAs(path: url.path)
                case .putAttachment(let id, let name, let data): try session.putAttachment(entry: id.uuidString, name: name, data: data)
                case .deleteAttachment(let id, let name): try session.deleteAttachment(entry: id.uuidString, name: name)
                }
                var saveFailure: VaultFailure?
                switch command {
                case .save, .saveAs, .reload:
                    break
                default:
                    do { try session.save() }
                    catch { saveFailure = (Self.failure(error) as? VaultFailure) ?? .writeFailed }
                }
                return VaultCommandResult(vault: try Self.map(session.snapshot()), saveFailure: saveFailure)
            }.value
            guard !Task.isCancelled, generation == request else { throw CancellationError() }
            if let url = result.vault.fileURL { self.url = url }
            knownGroups = result.vault.groups
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
            if let vault { knownGroups = vault.groups }
            return vault
        } catch {
            if (error as? CoreError) == .WrongCredentials { throw VaultFailure.credentialsChanged }
            throw Self.failure(error)
        }
    }

    func entry(_ id: UUID) async throws -> VaultEntry {
        guard let session else { throw VaultFailure.invalidOperation }
        let groups = knownGroups
        do {
            return try await Task.detached {
                return try Self.map(session.entry(id: id.uuidString), groups: groups)
            }.value
        } catch { throw Self.failure(error) }
    }

    func history(_ id: UUID) async throws -> [VaultEntry] {
        guard let session else { throw VaultFailure.invalidOperation }
        let groups = knownGroups
        do {
            return try await Task.detached {
                return try session.history(entry: id.uuidString).map { try Self.map($0, groups: groups) }
            }.value
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
                      customFields: item.customFields.map { CoreCustomField(name: $0.name, value: $0.value, protected: $0.isSensitive) })
    }

    nonisolated private static func groups(_ source: [CoreGroup]) throws -> [VaultGroup] {
        try source.map { g in
            guard let id = UUID(uuidString: g.id) else { throw VaultFailure.corruptedDatabase }
            return VaultGroup(id: id, name: g.name, parentID: g.parentId.flatMap(UUID.init(uuidString:)), path: g.path,
                              createdAt: g.createdAt.map { Date(timeIntervalSince1970: Double($0)) },
                              modifiedAt: g.modifiedAt.map { Date(timeIntervalSince1970: Double($0)) })
        }
    }

    nonisolated private static func map(_ source: CoreSnapshot) throws -> Vault {
        let groups = try groups(source.groups)
        return try Vault(name: source.info.name, groups: groups,
                         entries: source.entries.map {
                             var summary = try map($0, groups: groups)
                             summary.isRedacted = true
                             return summary
                         },
                         isDirty: source.info.dirty, fileURL: URL(fileURLWithPath: source.info.path))
    }

    nonisolated private static func map(_ e: CoreEntry, groups: [VaultGroup]) throws -> VaultEntry {
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
