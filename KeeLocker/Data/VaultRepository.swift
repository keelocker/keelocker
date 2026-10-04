import Foundation

@MainActor
protocol VaultRepository: AnyObject {
    var capabilities: VaultCapabilities { get }
    var requiresPassword: Bool { get }
    var supportsQuickUnlock: Bool { get }
    func load(password: String, keyFile: URL?) async throws -> Vault
    func load(keyMaterial: Data) async throws -> Vault
    func keyMaterial() async throws -> Data
    func execute(_ command: VaultCommand) async throws -> VaultCommandResult
    func refresh() async throws -> Vault?
    func entry(_ id: UUID) async throws -> VaultEntry
    func history(_ id: UUID) async throws -> [VaultEntry]
    func attachment(_ id: UUID, name: String) async throws -> Data
    func replaceEntries(_ entries: [VaultEntry])
    func lock()
}

extension VaultRepository {
    var supportsQuickUnlock: Bool { false }
    func load(keyMaterial: Data) async throws -> Vault { throw VaultFailure.invalidOperation }
    func keyMaterial() async throws -> Data { throw VaultFailure.invalidOperation }
    func refresh() async throws -> Vault? { nil }
    func history(_ id: UUID) async throws -> [VaultEntry] { [] }
    func attachment(_ id: UUID, name: String) async throws -> Data { throw VaultFailure.invalidOperation }
    func replaceEntries(_ entries: [VaultEntry]) {}
    func lock() {}
}
