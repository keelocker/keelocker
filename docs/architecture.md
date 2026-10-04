# Architecture and invariants

## Ownership and boundaries

```text
SwiftUI → VaultStore → VaultRepository
                       ├─ MemoryVaultRepository
                       └─ RustVaultRepository → generated UniFFI bindings → CoreVault
                                                                          ↓
                                                               vendored keepass
```

| Layer | Responsibility and source |
| --- | --- |
| Views | Existing macOS presentation, editors, dialogs and commands in [KeeLocker/Views](../KeeLocker/Views). Views use application models; they do not call the Rust API. |
| Application state | [VaultStore](../KeeLocker/Store/VaultStore.swift) owns lock/unlock state, selection, search, group scope/collapse, drafts, busy/dirty state and refresh scheduling. |
| Repository contract | [VaultRepository](../KeeLocker/Data/VaultRepository.swift) defines load, commands, refresh, details, history, attachments and lock. [Vault.swift](../KeeLocker/Models/Vault.swift) defines commands, capabilities, results and safe application failures. |
| Swift adapter | [RustVaultRepository](../KeeLocker/Data/Rust/RustVaultRepository.swift) owns the FFI handle, runs synchronous Rust calls in detached tasks, maps DTOs/errors, translates favorites and autosaves mutation commands. |
| Demo | [MemoryVaultRepository](../KeeLocker/Data/Memory/MemoryVaultRepository.swift) implements the same contract without persistent file writes. |
| Rust session | [CoreVault](../crates/keelocker-core/src/vault/mod.rs) owns the full database, credentials, source hash, dirty flag and future save preparation under a mutex. It exposes synchronous library operations, independent of AppKit/SwiftUI. |
| Rust data/format | [models](../crates/keelocker-core/src/models/mod.rs) contains owned FFI DTOs; [kdbx](../crates/keelocker-core/src/kdbx) contains compatibility, mapping, validation and file persistence. Cryptography and serialization use the patched library. |
| File observation | [VaultFileMonitor](../KeeLocker/Data/VaultFileMonitor.swift) is a macOS-specific Swift service. The store schedules repository refreshes from its notifications. |

The current backend is read/write. The earlier Swift KDBX integration is gone; new KDBX work belongs in Rust or its adapter. The backend selection is currently the direct `RustVaultRepository` construction in `VaultStore.openFile`, not a factory.

## Snapshots and selected entry details

Rust list snapshots omit secrets. The adapter marks their entries `isRedacted`; the selected entry and history are fetched separately with full fields. Never construct a replacement edit from a list row: an empty redacted password is not an instruction to erase the real password. `updateItem`, `saveItem` and the adapter reject redacted replacement edits.

The UI boundary uses `VaultEntry`, currently an alias for `VaultItem`, so it still includes presentation properties such as icon color. These models are independent of Rust but are not yet a standalone portable domain package. Search operates on the list projection; preserve its protection policy rather than fetching every password or protected field to extend search.

The adapter persists favorites with the standard `KeeLocker:Favorite` tag and hides that tag from the displayed tag list. Keep this mapping consistent in both directions so edits retain stars and other KeePass clients retain the data.

## Session lifetime and concurrency

- `VaultStore` and the Swift repositories are main-actor objects; crypto/file operations execute off that actor.
- Each unlock/replacement/lock changes the store session generation. Recheck the captured generation after suspension before publishing results or executing an action from a delayed dialog. Entry selection also has its own generation.
- Swift task cancellation does not interrupt a synchronous Rust operation. Late results must be ignored; a late successful open must close the newly opened handle.
- Keep `isBusy` active until the new snapshot and selected-entry details agree. If detail refresh fails, clear the old editable selection. After creating an entry, consume its draft before enabling another Save.
- Lock invalidates watchers, cancels UI tasks, clears groups, entries, selection, drafts and errors, and drops the adapter's session reference. Rust lock runs in the background because its mutex may be held by an in-flight operation. A save already running may finish.
- Rust drops its database/key on lock. A background KDF already running may finish and drop its result. Do not promise immediate cancellation or guaranteed zeroing of all Swift strings.

These are deliberate invariants covered by tests, not suggestions to simplify task handling.

## Session Quick Unlock

`VaultStore` accepts an optional `QuickUnlockService`. Production injects the
process-wide `SessionQuickUnlock`; demo and ordinary store tests have none.
Views receive availability and actions from the store. Native `LAContext` and
Secure Enclave operations stay in `Data/macOS/EnclaveQuickUnlockStorage.swift`.

After a successful password unlock on supported hardware, the Rust adapter automatically exports normalized
pre-KDF key components. The service retains only authenticated ciphertext in RAM.
Recovering its wrapping key requires a fresh biometric Secure Enclave operation;
the adapter then reopens and verifies KDBX with the original library/KDF. Lock drops
plaintext and the Rust session while retaining that encrypted cache. Quit clears
the cache. No master password, normalized key or native record is written to
preferences or Keychain. See [Touch ID contract](touch-id.md) for crypto and lifecycle details.

Cancel/Lock/window closure/session replacement invalidates the originating native
context and checks generation after each await. Invalidating a cache also cancels its
pending requests. Unavailable hardware skips enrollment; enrollment failure leaves
the successful password unlock intact. There is currently no enrollment preference
or toggle on the unlock form.
Changed credentials invalidate the cached material; Save As does not transfer
registration to the new path.
Enrollment captures a revision before password load, reserves before key export
and is tied to the opened canonical path. Intervening invalidation rejects stale
attempts. Biometric reopen rechecks the registration after KDBX opening and closes
revoked sessions before publishing their data.
Each unlocked store retains its registration token; failures from obsolete windows
cannot invalidate newer registrations. Native request bookkeeping is released at
completion even if cancellation happened outside the native operation.

## Drafts, mutations and persistence errors

`VaultStore.addItem` creates an application draft in the selected group (or database root), preserving the sidebar scope. It does not call the repository. Cancel restores the prior selection and leaves the file untouched. A draft created from Favorites starts starred.

Save issues `createEntry` or `updateEntry`. In the Rust adapter, every mutation then attempts `CoreVault.save`; explicit Save, Save As and Reload are handled separately. The Rust mutation methods themselves do not autosave, so other consumers must supply their own persistence policy.

`VaultCommandResult.saveFailure` distinguishes an applied mutation whose file write failed from a rejected mutation. An applied creation consumes its draft even if persistence failed; retain the created entry and dirty session for Save retry or Save Copy instead of creating it again. A rejected creation retains the draft for retry. Navigation, Open, Lock and exit guards must continue to protect drafts/unsaved edits.

Use capabilities to enable actions. Do not couple UI behavior to a `repository is RustVaultRepository` check. Empty groups can be deleted; entry deletion records a tombstone rather than moving the entry to the recycle bin.

## External changes and conflicts

The monitor watches both the directory and current file because atomic saves replace the inode; it also checks on app activation. Notifications are debounced. The store defers refresh while busy, dirty, editing a draft or inspecting history/attachments.

Rust compares the source hash and decrypts changed files before adopting them. A successful refresh retains valid selection, search/group scope and collapse state. Changed credentials require a fresh Lock/Unlock. Failed reloads retain the previous session and edits.

Conflicts offer Save Copy or explicit Reload Latest; the latter discards local changes only after successfully reading the external file. Save As refuses an existing different destination and moves monitoring to the new path. Do not replace this behavior with unconditional overwrite or automatic merge.

## Safe-save contract

Read [io.rs](../crates/keelocker-core/src/kdbx/io.rs) and [roundtrip.rs](../crates/keelocker-core/src/kdbx/roundtrip.rs) before changing saving:

1. Serialize with fresh library-generated encryption parameters, reopen and compare the complete model, including protected values, history and attachment bytes.
2. Write only encrypted bytes to a private temporary file in the destination directory and sync it.
3. For the opened file, verify its expected hash, create an encrypted `.bak`, recheck the source and atomically replace it. For a new destination, refuse replacement.
4. Sync the directory and update session state only after success.

Saving upgrades supported older databases to KDBX 4.1 while retaining cipher/KDF settings. Unknown structures the writer cannot preserve are rejected conservatively. History and shared attachment ownership must survive changes even when the UI does not expose those values.

Performance improvements reuse the KDF output only for validation of the bytes produced by that save and prepare one future save with a fresh salt per session. Preparations are consumed once, including failures. Keep validation and KDF strength intact; inspect the [vendor patch rationale](../vendor/keepass/KEELOCKER-PATCH.md) before modifying this path.

There is no multi-writer transaction: a small hash-check/rename race remains. Directory-sync failure can report failure after rename, and existing ACLs/extended attributes are not copied. Resource/KDF limits for hostile files are not implemented. Treat these as limitations, not guarantees to assume away.

## Reuse or replace the backend

The Rust crate exports a library and contains no macOS UI dependencies. Extraction must carry the workspace's `vendor/keepass` patch and tests/fixtures. Build scripts and checked-in bindings currently target macOS/Swift; mobile/Windows need their own packaging/bindings and filesystem verification. The current API accepts filesystem paths, so document providers may need a storage abstraction. File observation belongs to the host application.

A Swift replacement can implement `VaultRepository` and be selected in `VaultStore.openFile` without changing screens. Preserve capabilities, error mapping, redaction, async behavior and persistence/conflict semantics. Most migration work would be implementing and verifying equivalent KDBX behavior, not rewiring SwiftUI. Separate presentation properties from application models if extracting those models as a reusable package.
