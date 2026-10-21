import Foundation

struct VaultBackup: Identifiable, Sendable, Equatable {
    let id: String
    let createdAt: Date?
    let size: UInt64
    let isOriginal: Bool
}

struct VaultRecoveryResult: Sendable {
    let url: URL
    let directorySynced: Bool
}
