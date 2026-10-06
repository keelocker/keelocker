# Session Quick Unlock with Touch ID

Enter the master credentials after launch, then use Touch ID after Lock until
the process quits. Touch ID enrollment
is automatic after a successful password unlock on supported hardware. Lock clears
the UI and Rust database/key; only encrypted cached key material survives in RAM.
After Quit, crash or restart, the master credentials are required again. There is
no multi-day timer or persistent credential cache.

## User flow

1. Open a KDBX and enter its password/key file. Touch ID is enabled by default;
   the unlock form has no enrollment checkbox or disable control.
2. After successful KDBX decryption, confirm enrollment through the native
   biometric prompt. Cancellation/failure still leaves the password-opened vault
   usable, with a safe error and password fallback.
3. After Lock, choose **Unlock with Touch ID**. Every request uses a fresh
   authentication context. The vault is shown only after KDBX has opened successfully.
4. Quit clears session registrations. The master password/key file remains usable.
   There is currently no user setting to turn off automatic enrollment.

Touch ID is available only for persistent repositories on a Mac with both Touch
ID and Secure Enclave. The demo does not enroll. Availability is checked when the
unlock form appears, on app activation and before a biometric request. A lockout
or unavailable sensor leaves the normal unlock path accessible. Biometrics are
requested automatically only to enroll after successful password authentication.
Subsequent Touch ID unlocks require pressing the button; cancellation does not
retry automatically. Unavailable hardware skips enrollment without a Touch ID error.

## Protected material and native boundary

The Rust core exports `KLQ1` followed by one or two 32-byte normalized credential
components: hashed password and/or the library-parsed key-file component. These
are equivalent secrets for opening the vault, not harmless hashes. The library
continues to perform its normal KDF and authenticated KDBX parsing on every open.
Cipher/KDF parameters, strengths, salts and save validation remain unchanged.

`SessionQuickUnlock` encrypts this material with a fresh random AES-256-GCM key.
The canonical absolute vault path is authenticated as additional data. Its
dictionary retains ciphertext and a random registration ID, never the plaintext
components or master password.

`EnclaveQuickUnlockStorage` protects the AES key with standard CryptoKit primitives:

- Create a temporary Secure Enclave P-256 key-agreement private key with
  `WhenUnlockedThisDeviceOnly`, `privateKeyUsage` and `biometryCurrentSet` access control.
- Generate a temporary software P-256 peer. ECDH against the Enclave public key
  gives a shared secret; HKDF-SHA256 with the registration ID as salt and a fixed
  versioned context derives a 256-bit wrapping key. AES-GCM encrypts the random
  cache key with the registration ID as authenticated data.
- Verify the protected Enclave private-key operation during enrollment. Discard
  the software peer private key and plaintext wrapping keys afterwards.
- Retain only the device-wrapped Enclave private-key `dataRepresentation`, peer
  public key and encrypted AES key in an in-memory dictionary. The representation
  is opaque and device-bound; it is not an exported private scalar.
- Recovery reconstructs the Enclave key with a **fresh** `LAContext`, then performs
  the protected private-key agreement. The operating system enforces biometrics
  for the actual cryptographic operation. Decrypt the cache key, authenticate the
  cached material, and pass it to `VaultRepository.load(keyMaterial:)`.

Authentication reuse is zero; each context is invalidated after completion or
cancellation. The ACL uses the current biometric set without device-password,
Watch or generic user-presence alternatives. Adding/removing fingerprints makes
the key unusable; unlock manually and enroll again. Any fingerprint authorized
for that macOS account can satisfy the biometric policy.

## Native integration and signing

The temporary biometric Secure Enclave private key protects the in-memory cache.
KeeLocker creates no persistent Keychain item and has no fallback to ordinary
Keychain storage protected only by a software authentication check. Local builds
use the nonpersistent CryptoKit Enclave key without requiring an Apple Developer
Team. Native biometric verification must exercise the protected private-key
operation itself; a successful software authentication prompt is insufficient.

Apple API references: [Secure Enclave key agreement](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/keyagreement/privatekey),
[restoring the wrapped key with an authentication context](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/keyagreement/privatekey/init(datarepresentation:authenticationcontext:)),
[current biometric set ACL](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/biometrycurrentset),
[macOS Keychain distinctions](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

## Lifecycle and limits

- Cache identities resolve symlinks and standardize paths, matching Rust's
  canonicalized open path. Registrations are scoped per vault path in this process;
  moving a vault or Save As requires a password unlock to enroll the new path.
  Enrollment uses the opened snapshot's canonical path; the adapter retains it
  for later opens, so retargeting the original symlink cannot change the vault.
- Each window has a unique request ID. Lock or switching a vault cancels only its
  request; invalidating a vault cache cancels all requests for that cached identity.
  Generation and cache-registration checks reject late results after every await.
- Enrollment uses unique IDs so cleanup of an obsolete attempt cannot delete a
  newer registration. Cache invalidation removes the usable ciphertext synchronously; native
  record deletion follows asynchronously. Both dictionaries are memory-only.
  The service reserves enrollment before asynchronous key export. Replacement
  revokes that reservation; an old export cannot replace current credentials.
  A revision is captured before password loading; intervening replacement or
  invalidation prevents a late password result from enrolling obsolete material.
  Each unlocked window owns its registration token. Credential/recovery failures
  invalidate only that token; cancellation never removes a replacement cache.
  Recovery rechecks that token after KDBX opening, closing a revoked repository
  session before it can publish decrypted entries. It also compares the returned
  snapshot's already-canonical file path with the captured registration identity;
  resolving the original URL again cannot verify which file was actually opened.
  Rust binds that identity to the descriptor used for reading, checking its
  native path before and after the read. A retargeted canonical path is rejected
  even if it is restored before the Swift callback.
  A mismatched opened session is closed even if the original symlink is restored
  before the callback.
  Completion releases native cancellation bookkeeping, including requests
  cancelled before native authentication begins or after it finishes.
- External credential changes invalidate cached material when detected. A stale
  cache cannot decrypt changed KDBX; the user must unlock with current credentials.
  Installing file observation schedules an initial refresh to detect changes
  during enrollment. Drafts, busy operations and unsaved edits defer that refresh
  through the normal store rules.
- Key-file components are included in the session cache. The physical key file
  need not remain connected for Quick Unlock; it is needed again after Quit.
- Native crypto, KDBX opening and key export run outside the main actor. No secret
  material or detailed native error payload is logged or saved in preferences.
- Rust secret buffers use zeroizing owners. Swift clears owned temporary Data
  buffers where possible, but copied buffers/strings, swap, crash dumps and a
  compromised running process are outside any guaranteed zeroization claim.
  The app necessarily holds plaintext while the vault is unlocked.

Tests in `QuickUnlockTests.swift` inject synthetic storage to exercise lifecycle,
authentication failures, tampering, canonical scope, late completion and the Rust
key-file/save bridge. Rust `session_key_material_*` tests cover cipher/KDF/version
combinations and malformed or wrong material. Native fingerprint success and UI
behavior require a manual check on the host; fake storage is not evidence of
actual biometric authentication.
