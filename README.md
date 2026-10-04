# KeeLocker

Native SwiftUI macOS password manager with a Rust KDBX read/write core.
Open an existing database (⌘O), unlock, and edit. Changes to the open `.kdbx`
are saved automatically; Save (⌘S) retries a failed write and Save As (⇧⌘S)
creates a copy.
KeeLocker remembers the last selected file and offers to unlock it on the next
launch. Only its path is saved in preferences; the master password is not saved.
The editable in-memory demo remains available.

On a Mac with Touch ID and Secure Enclave, Touch ID is prepared automatically
after a successful master-password unlock. Confirm the native biometric prompt;
cancelling it still opens the vault with the password. After Lock, choose
**Unlock with Touch ID**. A full Quit or restart requires the master password again (and the key file
if used). The session cache contains encrypted key material in memory only;
Secure Enclave requires biometrics to recover it. No Apple Developer Team is
needed for this local build. Details: [Session Quick Unlock](docs/touch-id.md).

## Build

macOS 14+, Xcode 26+, and Rust installed through rustup. Verified toolchains:
Swift 6.4 / Xcode 27 beta and Rust 1.98.1 on Apple Silicon. The Xcode build phase
builds and statically links Rust. For universal builds install both
`aarch64-apple-darwin` and `x86_64-apple-darwin` Rust targets; Intel runtime is untested.

```sh
xcodebuild -project KeeLocker.xcodeproj -scheme KeeLocker -destination 'platform=macOS,arch=arm64' build
```

`Cargo.lock` pins dependencies. UniFFI Swift/header/module-map files are committed.
After exported API changes run `bash scripts/generate-bindings.sh`.

## Architecture

```text
SwiftUI → VaultStore → VaultRepository
                       ├─ MemoryVaultRepository
                       └─ RustVaultRepository → UniFFI → CoreVault

crates/keelocker-core/src/
├─ vault/      session and mutation commands
├─ models/     KeeLocker-owned FFI DTOs
├─ kdbx/       loading, compatibility guards, round-trip validation, safe save
└─ error.rs    safe error categories
```

`keepass` 0.15.0 handles parsing, encryption and serialization. UniFFI 0.32.2
provides the bridge in `KeeLocker/Data/Rust`. No KDBX library types reach SwiftUI.
Rust owns the complete database and DatabaseKey under a mutex; Swift requests
redacted lists and selected-entry/history details. File/crypto work runs off the
main thread. Lock clears UI snapshots and drops the Rust session; generation
checks reject stale results. An in-flight save completes before its mutex is
released. A background KDF preparation already running at Lock finishes and drops
its result; it cannot repopulate the closed session. Swift strings are not guaranteed to be zeroed.

The upstream writer is experimental. The pinned MIT-licensed source in
`vendor/keepass` includes parsing/reference fixes and compatibility guards;
see `vendor/keepass/KEELOCKER-PATCH.md`. KDBX cryptography stays in that library;
the optional session cache uses Apple's CryptoKit and biometric Secure Enclave keys.

## Supported behavior

- Read KDBX 3.1/4.0/4.1; write **4.1**, retaining cipher/KDF settings. Saving an
  older file upgrades its format version.
- Tested AES-256/ChaCha20, AES-KDF/Argon2d/Argon2id, protected values and key files.
- DatabaseName, with filename fallback; UUIDs, nested/empty groups, title,
  username/password/URL/notes/tags, protected custom fields, timestamps.
- Extra URLs remain standard custom fields, e.g. KP2A_URL. Recognized `otp`
  otpauth URIs generate live TOTP in Rust.
- Entry/group CRUD and moves through context menus. Group deletion requires an
  empty group; entry deletion records a tombstone, not a recycle-bin move.
- Attachment add/replace/delete/export and history inspection through
  **Attachments & History…**. Historical attachment versions are preserved.
- Metadata, arbitrary standard CustomData keys, public custom data, icons,
  auto-type settings and history are retained even when UI does not edit them.
- Favorites persist using the standard KDBX tag `KeeLocker:Favorite`. KeeLocker
  displays it as a star rather than a regular tag; other clients can see the tag.
- Entry, group and attachment changes save the opened file immediately. A failed
  write leaves the edit in memory, marks the vault unsaved, and shows an error;
  File → Save retries or Save As creates a copy. Open/Lock/window-close/Quit
  guard these unsaved changes. Finish/cancel an item draft before navigation.
- New login (toolbar + or ⌘N) opens an editable draft in the current group,
  without adding an entry or writing the file. Save creates and persists it;
  Cancel drops the draft and restores the previous selection. A new login from
  Favorites starts as a favorite so it remains in that section after saving.
- External saves update an unlocked vault automatically, including KeePassXC's
  atomic file replacement and in-place writes. Directory/file notifications are
  debounced, and returning to KeeLocker checks again. The source hash filters out
  KeeLocker's own saves; decryption and parsing run in Rust off the main thread.
  Selection, search and group scope are retained where still valid. Watchers stop
  on Lock and follow the destination after Save As.
- Automatic reload waits while editing an item or inspecting attachments/history,
  and never discards dirty changes. If both applications change the file, the
  conflict alert offers Save Copy or Reload Latest (discard local changes only
  after the file has been successfully read). Cancel retains the local changes.
  Changed master credentials require Lock/Unlock with the current credentials.
- Create folders with File → New Group… (⌘⇧N), inside the selected group or the
  database root from All items/Favorites. Right-click a group → New Group creates
  a child there; right-click the sidebar background → New Group creates a child
  of the database root regardless of selection. Group creation saves the opened
  vault immediately, selects the new folder and expands its ancestors.
- Sidebar groups show short names with indentation and disclosure arrows for
  branches. Collapsing a branch hides its descendants; if the selected group
  would be hidden, selection moves to that branch. Collapse state is kept during
  edits and external reloads, and cleared on Lock. Disclosure rotates the arrow
  and animates row appearance/position over 150 ms, without bounce or stagger.
  Reduce Motion disables these animations; they are scoped to the group tree.

## Safe save and limitations

Serialize with fresh library-generated salts/IVs → reopen → compare the complete
model, including protection/history/metadata/attachment bytes → same-directory
private temporary file → sync → atomic rename → directory sync. Validation
reuses this save's KDF output, avoiding a second Argon2/AES-KDF pass;
header and payload authentication, decryption and model comparison still run.
Each unlocked session prepares one future save key in the background, using a
fresh KDF salt and the unchanged database KDF parameters. The preparation is
consumed exactly once, including on failed writes. Its derived key is zeroized
after validation. The next preparation starts after each save attempt; nothing
is shared between vaults or persisted outside the KDBX. A save waits if preparation
is not ready yet. This moves KDF work into editing time rather than weakening it.
Opening decrypts once: compatibility checks and XML parsing share that payload.
Attachment validation hashes bytes directly instead of first expanding them into JSON.
Derived binary IDs and history-parent references are normalized during comparison. Save first
creates an encrypted `.bak` of the previous source. No plaintext is written by
vault saving. Existing ACLs/extended attributes are not copied.

Source SHA-256 is checked twice before replace. External modification returns
Conflict if local edits race an external save; clean sessions reload automatically.
Save As refuses an existing different destination. A small check/rename
race remains with non-cooperating writers: this is not multi-writer synchronization.
A directory-sync failure after rename can report WriteFailed although the new
file already exists; the encrypted backup permits recovery.

Unknown XML extensions/attributes, duplicate keys/UUIDs, unsupported KDF fields,
and nonempty KDBX4 header comments are rejected rather than discarded. Arbitrary
standard CustomData values are preserved. The guard is conservative and rejects
some valid third-party extensions. KDBX3.1 requires a valid embedded HeaderHash;
it is authenticated before protected fields are parsed and removed during the
4.1 upgrade. Older files without this authentication field are refused.
Malformed numeric header values return errors; parser panics are contained before
they can poison an open session. Failed reloads retain unsaved data for Save Copy.
List snapshots carry an explicit redaction marker and cannot be used as replacement
edits. Delayed file-dialog and attachment actions are bound to their source session.

Not implemented: new database creation, master-key changes, automatic merge,
history restoration/pruning, recycle-bin UI, field-reference expansion, auto-type
execution, icon editing, Keychain, cloud/sync, hardware keys. Twofish is
provided by the crate but outside the tested matrix. Hostile-file resource/KDF
limits are not yet implemented. Authentication-header damage can be
indistinguishable from wrong credentials; KDBX3 padding failure maps to that error.

## Tests

```sh
cargo test -p keelocker-core -- --include-ignored --skip save_timing --skip operation_timing
xcodebuild -project KeeLocker.xcodeproj -scheme KeeLocker -destination 'platform=macOS,arch=arm64' -only-testing:KeeLockerTests test
```

Ignored Rust interop tests require KeePassXC CLI; override its macOS path with
`KEEPASSXC_CLI`. They cover 16 combinations of KDBX 4.0/4.1 × Argon2d/id ×
AES/ChaCha20 × password/password+keyfile. KeePassXC rewrites a fixture, Rust edits
and saves a copy, KeePassXC exports/edits it, then Rust reopens it. Independent
KeePassXC-created/imported 3.1 fixtures are also tested. Regression coverage
includes metadata, custom icons, UUIDs/timestamps, historical attachments,
corruption, conflicts and lock. Credentials are synthetic; see fixtures README.

Manual performance checks (release mode, synthetic fixtures only):
`cargo test --release -p keelocker-core operation_timing -- --ignored --nocapture`.
This measures opening, snapshots, immediate saves and saves after a 400 ms editing
pause for Argon2id, AES-KDF, an 8 MiB attachment, and 5000 entries. Timing is not a
CI assertion. On this Apple Silicon host, Argon2id saves after the pause fell from
about 208 ms to 11 ms; saving immediately after unlock can still wait for the KDF.

The existing toolbar tests use `--demo-vault`; a real-file UI test uses the native
picker. XCTest UI execution requires host automation support.

Verified on 2026-09-28: Rust 10/10 tests (including 16 KeePassXC configurations),
Swift 13/13 unit/bridge tests, and the macOS debug app build pass. Native UI
checks covered Open → Unlock → Save As → Edit → Save → create group/entry → Save
→ Quit → reopen, plus the unsaved-Quit guard. KeePassXC successfully opened the
UI-saved copy and confirmed its edits. The full automated toolbar UI suite is
not claimed as passed: the earlier XCTest runner timed out enabling automation.

Verified on 2026-09-29: 14 KeeLocker unit/bridge tests pass, including direct
autosave to the opened file and conflict recovery through Save As.

Verified on 2026-09-30: Rust 17/17 tests (including the KeePassXC matrix) and
Swift 22/22 unit/bridge tests pass. The new external-save regression failed before
the fix and passes with automatic reload. Coverage includes repeated atomic and
in-place saves, deleted selections, changed groups/KDFs/credentials, draft
preservation, conflict recovery, Save As monitoring, and late refresh after Lock.
Manual native UI verification used a separate app identity and a temporary vault:
KeePassXC CLI edit → live list/details update → KeeLocker Edit/Save → simultaneous
external save → conflict alert → Reload Latest. The dedicated XCTest UI test is
included, but its runner could not initialize because macOS returned
"Authentication canceled. System authentication is running."

Sidebar hierarchy verification on 2026-09-30: the existing 22 Swift tests and two
new tree/selection tests pass, with a successful macOS debug build. Native UI
checks on a temporary KDBX covered short names/indentation, collapse/expand,
creating inside a collapsed group, and creating at root from empty sidebar space
while a nested group was selected. KeePassXC CLI reopened the saved file and
confirmed both new groups in the expected parents.

New-entry draft verification on 2026-10-01: 28 Swift unit/bridge tests and the
macOS debug build pass. The new regression test reproduced immediate creation
and the All items jump before the fix. Coverage includes Save, Cancel, creation
failure/retry, Favorites, Lock, and reopening the saved KDBX. Native verification
on a temporary database covered + and ⌘N inside a nested group, editable fields,
Cancel restoring the previous entry, and Save selecting the new entry without
changing group. The file hash stayed unchanged while typing and after Cancel;
KeePassXC CLI successfully read the new entry after Save.

Deep review verification on 2026-10-01: 33 Swift unit/bridge tests and 27 Rust
tests pass, including the KeePassXC matrix. New regressions reproduce stale
details during external refresh, repeat creation during draft Save, redacted
replacement edits, KDBX3 header tampering, malformed-header reload recovery,
shared/historical attachments, sparse binary IDs, custom-icon group deletion,
rejected moves and invalid tag delimiters. Generated UniFFI files match the API;
Clippy with warnings denied, formatting and the macOS debug build pass.
