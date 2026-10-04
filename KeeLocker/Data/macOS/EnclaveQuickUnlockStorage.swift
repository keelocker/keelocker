import Foundation
import CryptoKit
import LocalAuthentication
import Security

/// All records are ephemeral. Secure Enclave enforces biometrics on the private-key operation.
final class EnclaveQuickUnlockStorage: QuickUnlockKeyStorage, @unchecked Sendable {
    private struct Record: Sendable {
        let privateKey: Data // Device-wrapped representation; never the private scalar.
        let peer: Data
        let ciphertext: Data
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var contexts: [UUID: LAContext] = [:]
    private var cancelled: Set<UUID> = []

    func isAvailable() -> Bool {
        let context = LAContext()
        defer { context.invalidate() }
        return SecureEnclave.isAvailable
            && context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            && context.biometryType == .touchID
    }

    func store(_ key: Data, account: String, request: UUID) async throws {
        let context = try begin(request, reason: "Enable Touch ID until you quit KeeLocker")
        defer { finish(request) }
        do {
            let record = try await Task.detached(priority: .userInitiated) {
                var error: Unmanaged<CFError>?
                guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                                  [.privateKeyUsage, .biometryCurrentSet], &error) else {
                    throw QuickUnlockFailure.storageFailed
                }
                let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context)
                let peer = P256.KeyAgreement.PrivateKey()
                let shared = try peer.sharedSecretFromKeyAgreement(with: enclave.publicKey)
                let wrapping = Self.derive(shared, account: account)
                let aad = Data(account.utf8)
                guard let ciphertext = try AES.GCM.seal(key, using: wrapping, authenticating: aad).combined else {
                    throw QuickUnlockFailure.storageFailed
                }
                // Test the protected operation during enrollment. No software-only authentication gate.
                let authenticated = try enclave.sharedSecretFromKeyAgreement(with: peer.publicKey)
                var restored = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext),
                                               using: Self.derive(authenticated, account: account), authenticating: aad)
                defer { restored.resetBytes(in: 0..<restored.count) }
                guard restored == key else { throw QuickUnlockFailure.invalidMaterial }
                return Record(privateKey: enclave.dataRepresentation, peer: peer.publicKey.x963Representation, ciphertext: ciphertext)
            }.value
            try Task.checkCancellation()
            try insert(record, account: account, request: request)
        } catch { throw Self.failure(error) }
    }

    func read(account: String, request: UUID) async throws -> Data {
        let context = try begin(request, reason: "Unlock your vault")
        defer { finish(request) }
        guard let record = record(account) else { throw QuickUnlockFailure.missingKey }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                // A fresh context for each request prevents reusing an earlier authentication.
                let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: record.privateKey,
                                                                             authenticationContext: context)
                let peer = try P256.KeyAgreement.PublicKey(x963Representation: record.peer)
                let shared = try enclave.sharedSecretFromKeyAgreement(with: peer)
                return try AES.GCM.open(AES.GCM.SealedBox(combined: record.ciphertext),
                                        using: Self.derive(shared, account: account), authenticating: Data(account.utf8))
            }.value
            try Task.checkCancellation()
            return result
        } catch { throw Self.failure(error) }
    }

    func delete(account: String) async throws { remove(account) }

    func cancel(request: UUID) {
        lock.lock()
        cancelled.insert(request)
        let context = contexts.removeValue(forKey: request)
        lock.unlock()
        context?.invalidate()
    }

    func finishRequest(_ request: UUID) { finish(request) }

    private func begin(_ request: UUID, reason: String) throws -> LAContext {
        lock.lock()
        defer { lock.unlock() }
        guard !Task.isCancelled, !cancelled.contains(request) else { throw CancellationError() }
        let context = LAContext()
        context.localizedReason = reason
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        contexts[request] = context
        return context
    }

    private func finish(_ request: UUID) {
        lock.lock()
        cancelled.remove(request)
        let context = contexts.removeValue(forKey: request)
        lock.unlock()
        context?.invalidate()
    }

    private func insert(_ record: Record, account: String, request: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard contexts[request] != nil, !cancelled.contains(request) else { throw CancellationError() }
        records[account] = record
    }

    private func record(_ account: String) -> Record? {
        lock.lock()
        defer { lock.unlock() }
        return records[account]
    }

    private func remove(_ account: String) {
        lock.lock()
        defer { lock.unlock() }
        records.removeValue(forKey: account)
    }

    private static func derive(_ shared: SharedSecret, account: String) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(account.utf8),
                                      sharedInfo: Data("KeeLocker session Quick Unlock v1".utf8), outputByteCount: 32)
    }

    private static func failure(_ error: Error) -> Error {
        if error is CancellationError || error is QuickUnlockFailure { return error }
        let native = error as NSError
        if native.domain == LAError.errorDomain {
            switch LAError.Code(rawValue: native.code) {
            case .userCancel, .appCancel, .systemCancel, .userFallback: return QuickUnlockFailure.cancelled
            case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout, .passcodeNotSet, .notInteractive:
                return QuickUnlockFailure.unavailable
            default: return QuickUnlockFailure.authenticationFailed
            }
        }
        switch native.code {
        case Int(errSecUserCanceled): return QuickUnlockFailure.cancelled
        case Int(errSecAuthFailed): return QuickUnlockFailure.authenticationFailed
        case Int(errSecInteractionNotAllowed), Int(errSecNotAvailable): return QuickUnlockFailure.unavailable
        default: return QuickUnlockFailure.storageFailed
        }
    }
}
