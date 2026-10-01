import Foundation

// Keep the existing UI's VaultItem vocabulary at the application boundary.
typealias VaultEntry = VaultItem

struct Vault: Sendable {
    var name: String
    var groups: [VaultGroup]
    var entries: [VaultEntry]
    var isDirty = false
    var fileURL: URL? = nil
}

struct VaultCommandResult: Sendable {
    let vault: Vault
    var saveFailure: VaultFailure? = nil
}

struct VaultCapabilities: Equatable, Sendable {
    let canCreate: Bool
    let canEdit: Bool
    let canDelete: Bool
    var canSave = false
    var canFavorite = true

    static let readOnly = Self(canCreate: false, canEdit: false, canDelete: false)
    static let editable = Self(canCreate: true, canEdit: true, canDelete: true)
    static let persistent = Self(canCreate: true, canEdit: true, canDelete: true, canSave: true)
}

enum VaultState: Equatable {
    case noVault
    case locked
    case unlocking
    case unlocked
    case error(VaultFailure)
}

enum VaultFailure: Error, Equatable, Sendable {
    case wrongPassword
    case unsupportedDatabase
    case corruptedDatabase
    case failedToReadFile
    case writeFailed
    case conflict
    case destinationExists
    case credentialsChanged
    case invalidOperation

    var title: String {
        switch self {
        case .wrongPassword: "Wrong password"
        case .unsupportedDatabase: "Unsupported database"
        case .corruptedDatabase: "Corrupted database"
        case .failedToReadFile: "Failed to read file"
        case .writeFailed: "Couldn’t save vault"
        case .conflict: "File has changed"
        case .destinationExists: "File already exists"
        case .credentialsChanged: "Vault credentials have changed"
        case .invalidOperation: "Couldn’t complete operation"
        }
    }

    var message: String {
        switch self {
        case .wrongPassword:
            "Couldn’t unlock this vault. Check the master password and try again."
        case .unsupportedDatabase:
            "This vault uses a format or encryption setting that isn’t supported."
        case .corruptedDatabase:
            "This vault appears to be damaged or incomplete. Try another copy."
        case .failedToReadFile:
            "Couldn’t read this file. Check that it is available and you have permission to open it."
        case .writeFailed:
            "Changes remain in memory. Check the file and permissions, then try File → Save again or Save As."
        case .conflict:
            "Another application changed this vault. Your unsaved changes remain in KeeLocker. Save a copy to keep them, or reload the latest file to discard them."
        case .destinationExists:
            "Choose a new filename to save a copy without replacing an existing vault."
        case .credentialsChanged:
            "Lock this vault and unlock it again with its current master password and key file."
        case .invalidOperation:
            "Check the selected item and destination. Groups must be empty before deletion, and cannot be moved into their own descendants."
        }
    }
}

enum VaultCommand: Sendable {
    case createEntry(VaultEntry)
    case updateEntry(VaultEntry)
    case deleteEntry(UUID)
    case moveEntry(UUID, UUID)
    case createGroup(parent: UUID, name: String)
    case renameGroup(UUID, String)
    case deleteGroup(UUID)
    case moveGroup(UUID, UUID)
    case save
    case reload
    case saveAs(URL)
    case putAttachment(UUID, String, Data)
    case deleteAttachment(UUID, String)
}

struct AttachmentMetadata: Identifiable, Hashable, Sendable {
    var name: String
    var size: UInt64
    var id: String { name }
}
