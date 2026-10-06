# KeeLocker

KeeLocker is a native SwiftUI password manager for macOS with a Rust KDBX core.
It opens and edits existing KeePass vaults while preserving data used by other
KeePass clients.

**Early development:** the KDBX writer and compatibility checks are still being
tested. Use a copy of your vault and keep an independent backup before trying it.
There is no stable release or guarantee that every third-party vault is supported.

macOS is the current platform. There are no iOS, Android or Windows app targets.

## Use

Open a `.kdbx` with **File → Open** (⌘O), then enter its password and optional key
file. Existing entry, group and attachment changes save automatically. A new
entry stays a draft until **Save**; **Cancel** leaves the file untouched.
**File → Save** (⌘S) retries a failed write, and **Save As** (⇧⌘S) creates a copy.

KeeLocker remembers the last selected vault's path, but never saves the master
password in preferences. An editable in-memory demo is also available.

On a Mac with Touch ID and Secure Enclave, a successful password unlock prepares
Touch ID automatically. Cancelling enrollment leaves the vault open. After
**Lock**, choose **Unlock with Touch ID**. Quit or restart clears the encrypted
memory cache, so the next launch needs the password and key file again.
See [Session Quick Unlock](docs/touch-id.md) for the protection model and limits.

## Supported behavior

- Read KDBX 3.1, 4.0 and 4.1; save as **4.1**, retaining cipher and KDF settings.
  The interoperability tests cover AES-256/ChaCha20, AES-KDF/Argon2d/Argon2id,
  protected values and key files.
- Edit entries, nested groups, tags and protected custom fields. Add, replace,
  delete and export attachments; inspect entry history. Empty groups can be
  deleted; deleting an entry records a tombstone.
- Display live TOTP from recognized `otp` otpauth URIs. Extra URLs remain custom
  fields; HOTP and unknown OTP kinds remain raw fields without TOTP display.
  Favorites use the standard tag `KeeLocker:Favorite`.
- Preserve metadata, UUIDs, timestamps, history, historical attachments, icons,
  auto-type settings and standard CustomData even when the UI cannot edit them.
  Entry mutations honor the database's history retention limits.
- Reload external changes while unlocked, including atomic saves by KeePassXC.
  Reload waits during editing or attachment/history inspection and preserves
  valid selection and group scope. Conflicts offer **Save Copy** or an explicit
  **Reload Latest**; failed reads retain local changes.
- Clear decrypted application state on Lock. File and cryptographic work runs
  outside the main thread.

Database creation, master-key changes, automatic merge, history restoration,
recycle-bin UI, field-reference expansion, auto-type execution, icon editing,
persistent Keychain unlock, cloud sync and hardware keys are not implemented.
Twofish is outside the tested interoperability matrix.

## Safe save and limitations

Before writing, KeeLocker serializes encrypted KDBX, reopens it and compares the
complete model, including protected values, metadata, history and attachment
bytes. It writes a private temporary file beside the destination, syncs it,
creates an encrypted `.bak` of the previous source, checks for external changes
and atomically replaces the source. Vault saving writes no plaintext. Attachment
export deliberately writes the selected attachment to the chosen destination.

A failed write keeps the edit in memory and marks the vault unsaved. Save retries
the write; Save As preserves a separate copy. Open, Lock and exit guard unsaved
changes. Save As refuses an existing different destination.

- Saving an older supported file upgrades it to KDBX 4.1. Compatibility guards
  reject unknown structures the writer cannot preserve, including some valid
  third-party extensions. KDBX 3.1 requires its embedded HeaderHash.
- Hash checks reduce conflicts but do not synchronize multiple writers. A small
  check/rename race remains with other clients. A directory-sync failure can be
  reported after replacement has committed. KeeLocker retains the written path
  and hash, keeps the session dirty with a durability warning, and allows Save to
  retry. If Save As committed, the session adopts its destination despite that
  warning. The encrypted backup remains a recovery option.
- Existing ACLs and extended attributes are not copied. Keep independent backups
  and verify permissions when using shared or managed files.
- Hostile-file resource and KDF limits are not implemented. Some authentication
  damage is indistinguishable from wrong credentials. Swift strings and copied
  buffers are not guaranteed to be zeroed; plaintext exists while unlocked.

The [architecture document](docs/architecture.md) specifies save validation,
session lifetime and conflict recovery. KDBX parsing, encryption and KDFs use the
vendored `keepass` library with a [preservation patch](vendor/keepass/KEELOCKER-PATCH.md).

## Build

Use macOS 14 or newer, Xcode 26 or newer, and Rust installed through rustup.
The Rust minimum version and dependencies are declared in
[Cargo.toml](crates/keelocker-core/Cargo.toml); `Cargo.lock` pins dependency resolution.
Run from the repository root on Apple Silicon:

```sh
rustup target add aarch64-apple-darwin
xcodebuild -project KeeLocker.xcodeproj -scheme KeeLocker -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/keelocker-derived build
```

The Xcode phase builds and links Rust. Universal builds also require
`x86_64-apple-darwin`; Intel runtime remains unverified. Local builds do not
require an Apple Developer Team. Generated UniFFI Swift, header and module-map
files are committed; exported API changes require regeneration.

## Development

```sh
cargo test --locked -p keelocker-core
cargo fmt --all -- --check
cargo clippy --locked -p keelocker-core --all-targets -- -D warnings
bash scripts/check-bindings.sh
xcodebuild -project KeeLocker.xcodeproj -scheme KeeLocker -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/keelocker-derived -only-testing:KeeLockerTests test
```

Use the host's command wrapper where required. Independent KeePassXC tests,
native UI checks and performance diagnostics have additional requirements in
[Development and verification](docs/development.md). Fixtures and credentials
are synthetic; see their [provenance](KeeLockerTests/Fixtures/README.md).

The [CI workflow](.github/workflows/ci.yml) defines Rust MSRV/stable checks,
KeePassXC interoperability, binding comparison and macOS build/Swift tests.
Native UI automation and fingerprint success require host support and manual
verification; they are not covered by the hosted workflow.

Contributions: [CONTRIBUTING.md](CONTRIBUTING.md).
Security reporting and reporting-channel status: [SECURITY.md](SECURITY.md).

## License

KeeLocker's own code is [MIT licensed](LICENSE). Dependencies retain their own
licenses; see [third-party notices](THIRD_PARTY_NOTICES.md) and the vendored
library's license.
