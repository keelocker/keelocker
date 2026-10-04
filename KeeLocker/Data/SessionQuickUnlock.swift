import Foundation
import CryptoKit

enum QuickUnlockFailure: Error, Equatable, Sendable {
    case cancelled, unavailable, authenticationFailed, missingKey, storageFailed, invalidMaterial

    var message: String {
        switch self {
        case .cancelled: "Touch ID was cancelled. You can unlock with your master password."
        case .unavailable: "Touch ID is unavailable. Unlock with your master password."
        case .authenticationFailed: "Touch ID couldn’t authenticate you. Try again or use your master password."
        case .missingKey: "Quick Unlock is no longer available. Unlock with your master password to enable it again."
        case .storageFailed: "Couldn’t access the protected Quick Unlock key. Your master password still works."
        case .invalidMaterial: "Couldn’t restore the Quick Unlock key. Unlock with your master password."
        }
    }
}

protocol QuickUnlockKeyStorage: Sendable {
    func isAvailable() -> Bool
    func store(_ key: Data, account: String, request: UUID) async throws
    func read(account: String, request: UUID) async throws -> Data
    func delete(account: String) async throws
    func cancel(request: UUID)
    func finishRequest(_ request: UUID)
}

extension QuickUnlockKeyStorage {
    func finishRequest(_ request: UUID) {}
}

/// Opaque ownership token bound to one canonical vault and one enrollment.
struct QuickUnlockRegistration: Equatable, Sendable {
    fileprivate let identity: String
    fileprivate let account: String
}

struct QuickUnlockEnrollmentAttempt: Sendable {
    fileprivate let identity: String
    fileprivate let revision: UUID
}

@MainActor
protocol QuickUnlockService: AnyObject {
    var isAvailable: Bool { get }
    func contains(_ url: URL) -> Bool
    func registration(for url: URL) -> QuickUnlockRegistration?
    func enrollmentAttempt(for url: URL) -> QuickUnlockEnrollmentAttempt
    func prepareEnrollment(for url: URL, request: UUID, attempt: QuickUnlockEnrollmentAttempt) throws -> QuickUnlockRegistration
    func cache(_ material: Data, registration: QuickUnlockRegistration, request: UUID) async throws
    func recover(registration: QuickUnlockRegistration, request: UUID) async throws -> Data
    func cancel(request: UUID)
    func finish(request: UUID)
    func forget(_ url: URL)
    func forget(_ registration: QuickUnlockRegistration)
    func forget(_ attempt: QuickUnlockEnrollmentAttempt)
}

extension QuickUnlockService {
    func cache(_ material: Data, for url: URL, request: UUID) async throws {
        let registration = try prepareEnrollment(for: url, request: request, attempt: enrollmentAttempt(for: url))
        defer { finish(request: request) }
        try await cache(material, registration: registration, request: request)
    }

    func recover(for url: URL, request: UUID) async throws -> Data {
        guard let registration = registration(for: url) else { throw QuickUnlockFailure.missingKey }
        return try await recover(registration: registration, request: request)
    }
}

/// Only authenticated ciphertext survives Lock. No database credentials are written to disk.
@MainActor
final class SessionQuickUnlock: QuickUnlockService {
    static let shared = SessionQuickUnlock(storage: EnclaveQuickUnlockStorage())

    private struct Record {
        let account: String
        let ciphertext: Data
    }

    private let storage: any QuickUnlockKeyStorage
    private var records: [String: Record] = [:]
    private var pending: [UUID: QuickUnlockRegistration] = [:]
    private var revisions: [String: UUID] = [:]

    init(storage: any QuickUnlockKeyStorage) { self.storage = storage }

    var isAvailable: Bool { storage.isAvailable() }

    func contains(_ url: URL) -> Bool { records[identity(url)] != nil }

    func registration(for url: URL) -> QuickUnlockRegistration? {
        let id = identity(url)
        guard let record = records[id] else { return nil }
        return QuickUnlockRegistration(identity: id, account: record.account)
    }

    func enrollmentAttempt(for url: URL) -> QuickUnlockEnrollmentAttempt {
        let id = identity(url)
        let revision = revisions[id] ?? UUID()
        revisions[id] = revision
        return QuickUnlockEnrollmentAttempt(identity: id, revision: revision)
    }

    func prepareEnrollment(for url: URL, request: UUID, attempt: QuickUnlockEnrollmentAttempt) throws -> QuickUnlockRegistration {
        try Task.checkCancellation()
        guard isAvailable else { throw QuickUnlockFailure.unavailable }
        let id = identity(url)
        guard attempt.identity == id, revisions[id] == attempt.revision else { throw CancellationError() }
        forgetIdentity(id)
        let registration = QuickUnlockRegistration(identity: id, account: UUID().uuidString)
        pending[request] = registration
        return registration
    }

    func cache(_ material: Data, registration: QuickUnlockRegistration, request: UUID) async throws {
        defer { finish(request: request) }
        guard !Task.isCancelled, pending[request] == registration else { throw CancellationError() }
        let id = registration.identity
        let account = registration.account
        let sealed = try await Task.detached(priority: .userInitiated) {
            let key = SymmetricKey(size: .bits256)
            guard let ciphertext = try AES.GCM.seal(material, using: key, authenticating: Data(id.utf8)).combined else {
                throw QuickUnlockFailure.invalidMaterial
            }
            return (ciphertext, key.withUnsafeBytes { Data($0) })
        }.value
        var keyData = sealed.1
        defer { keyData.resetBytes(in: 0..<keyData.count) }
        do {
            guard !Task.isCancelled, pending[request] == registration else { throw CancellationError() }
            try await storage.store(keyData, account: account, request: request)
            guard !Task.isCancelled, pending[request] == registration else { throw CancellationError() }
            let previous = records.updateValue(Record(account: account, ciphertext: sealed.0), forKey: id)
            if let previous { deleteLater(previous.account) }
        } catch {
            deleteLater(account)
            throw error
        }
    }

    func recover(registration: QuickUnlockRegistration, request: UUID) async throws -> Data {
        try Task.checkCancellation()
        let id = registration.identity
        guard let record = records[id], record.account == registration.account else { throw QuickUnlockFailure.missingKey }
        guard isAvailable else { throw QuickUnlockFailure.unavailable }
        pending[request] = registration
        defer { finish(request: request) }
        var keyData = try await storage.read(account: record.account, request: request)
        defer { keyData.resetBytes(in: 0..<keyData.count) }
        guard !Task.isCancelled, pending[request] == registration else { throw CancellationError() }
        guard records[id]?.account == record.account else { throw QuickUnlockFailure.missingKey }
        guard keyData.count == 32 else { throw QuickUnlockFailure.invalidMaterial }
        let decryptionKey = keyData
        let material = try await Task.detached(priority: .userInitiated) {
            do {
                return try AES.GCM.open(AES.GCM.SealedBox(combined: record.ciphertext),
                                       using: SymmetricKey(data: decryptionKey), authenticating: Data(id.utf8))
            } catch { throw QuickUnlockFailure.invalidMaterial }
        }.value
        guard !Task.isCancelled, pending[request] == registration, records[id]?.account == record.account else {
            throw CancellationError()
        }
        return material
    }

    func cancel(request: UUID) {
        guard pending.removeValue(forKey: request) != nil else { return }
        storage.cancel(request: request)
    }

    func finish(request: UUID) {
        pending.removeValue(forKey: request)
        storage.finishRequest(request)
    }

    func forget(_ url: URL) {
        forgetIdentity(identity(url))
    }

    private func forgetIdentity(_ id: String) {
        revisions[id] = UUID()
        for request in pending.filter({ $0.value.identity == id }).map(\.key) { cancel(request: request) }
        if let record = records.removeValue(forKey: id) { deleteLater(record.account) }
    }

    func forget(_ registration: QuickUnlockRegistration) {
        let requests = pending.filter({ $0.value == registration }).map(\.key)
        let ownsRecord = records[registration.identity]?.account == registration.account
        if ownsRecord || !requests.isEmpty { revisions[registration.identity] = UUID() }
        for request in requests { cancel(request: request) }
        if ownsRecord,
           let record = records.removeValue(forKey: registration.identity) { deleteLater(record.account) }
    }

    func forget(_ attempt: QuickUnlockEnrollmentAttempt) {
        guard revisions[attempt.identity] == attempt.revision else { return }
        forgetIdentity(attempt.identity)
    }

    func reset() {
        for request in Array(pending.keys) { cancel(request: request) }
        let accounts = records.values.map(\.account)
        records.removeAll()
        revisions.removeAll()
        for account in accounts { deleteLater(account) }
    }

    private func deleteLater(_ account: String) {
        let storage = storage
        // The native record contains only encrypted data and a device-wrapped private key.
        Task { try? await storage.delete(account: account) }
    }

    private func identity(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
