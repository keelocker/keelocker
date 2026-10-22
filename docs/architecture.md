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

History inspection reloads on an applied snapshot revision rather than history
count or timestamps: retention can replace a version without changing either.
Clear the previous selection and check cancellation before publishing a new
history result so a revoked task cannot restore stale versions.

## Session lifetime and concurrency

- `VaultStore` and the Swift repositories are main-actor objects; crypto/file operations execute off that actor.
- Each unlock/replacement/lock changes the store session generation. Recheck the captured generation after suspension before publishing results or executing an action from a delayed dialog. Entry selection also has its own generation.
- Swift task cancellation does not interrupt a synchronous Rust operation. Late results must be ignored; a late successful open must close the newly opened handle.
- Rust verifies the native descriptor path against the captured canonical identity before and after reading bytes for open, reload and save conflict checks. Resolving the pathname again cannot detect a symlink retargeted and restored during open. Apple hosts use `F_GETPATH`; Linux uses `/proc/self/fd` and requires procfs. Unsupported hosts fail closed until a descriptor identity implementation is added.
- `VaultLoadAdmission` in the Rust adapter admits one open per canonical vault path and keeps only the latest queued request for that path. Its slot covers opening, snapshot creation and cleanup of a rejected late session; cancellation cannot release a still-running native call. Different vault paths remain independent. Shared admission state stores request metadata, not credential closures.
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
attempts. Biometric reopen compares the repository's already-canonical opened
path to the captured registration identity and rechecks the registration token
after KDBX opening. Do not resolve the original path again for that comparison:
a symlink may have been retargeted while opening. Close mismatched or revoked
sessions before publishing their data.
Each unlocked store retains its registration token; failures from obsolete windows
cannot invalidate newer registrations. Native request bookkeeping is released at
completion even if cancellation happened outside the native operation.

## Drafts, mutations and persistence errors

Attachment import opens a regular-file descriptor off the main actor and reads
incrementally with a 64 MiB bound, including a growth check beyond the limit.
Reject oversized or special files before passing bytes across the repository
boundary. Session and inspection guards still discard obsolete import results.

`VaultStore.addItem` creates an application draft in the selected group (or database root), preserving the sidebar scope. It does not call the repository. Cancel restores the prior selection and leaves the file untouched. A draft created from Favorites starts starred.

Save issues `createEntry` or `updateEntry`. In the Rust adapter, every mutation then attempts `CoreVault.save`; explicit Save, Save As and Reload are handled separately. The Rust mutation methods themselves do not autosave, so other consumers must supply their own persistence policy.

`VaultCommandResult.saveFailure` distinguishes an applied mutation whose file write failed from a rejected mutation. An applied creation consumes its draft even if persistence failed; retain the created entry and dirty session for Save retry or Save Copy instead of creating it again. A rejected creation retains the draft for retry. Navigation, Open, Lock and exit guards must continue to protect drafts/unsaved edits.

Explicit Save and Save As return the current snapshot with `saveFailure` when
Rust reports `WriteFailed`. The adapter adopts that snapshot's path and the store
updates observation even when directory sync failed after a committed Save As.
Do not keep the previous path or discard the committed snapshot because the
operation carries a durability warning.

Use capabilities to enable actions. Do not couple UI behavior to a
`repository is RustVaultRepository` check. Empty groups can be deleted. Entry
deletion honors the imported recycle-bin setting (absent defaults to enabled).
Enabled deletion moves into a valid bin or creates one, preserving the entry's
UUID, history and assets. A stale/root bin UUID is never treated as the trash
subtree. Existing nested groups inside the bin remain part of the trash.
Trash and Restore use location-only moves with previous-parent/location-time
updates. They never checkpoint or prune history, even at imported retention
capacity; ordinary edits and moves continue to honor those limits.
Only an explicit permanent-delete command destroys an entry already in trash;
when the imported setting is disabled, the ordinary deletion confirmation
explicitly describes permanent destruction. Final deletion records a tombstone.
Restore uses the saved previous parent when it still exists outside trash,
otherwise the database root. The store excludes the bin subtree from active
counts, search, favorites, normal group destinations and automatic icon changes.
Trashed entries remain inspectable and have Restore/Delete Permanently actions.

Tag input stays verbatim in the editing draft. Split semicolon-delimited input,
trim each tag and remove empty values only when constructing the saved entry.
Reformatting after every keystroke can change the next typed value.

## Entry icons

Entries expose standard KDBX icon IDs or custom icon references through the
application models; Rust DTOs remain inside the Rust adapter. SF Symbols and tile
colors are presentation mappings for the 69 standard KeePass IDs. The demo's
existing artwork remains the fallback until an explicit icon choice is saved.
Unrecognized stored standard IDs use a visual fallback and survive unrelated
edits. A nil icon edit means preserve, rather than clear or replace.

Snapshots include a vault-scoped catalog of custom UUIDs, names and image bytes,
including icons retained by history or groups. Detail/history reads use
`inspect_entry`, which returns their groups, icons and requested history under
one Rust session mutex; inspections copy only the images referenced by the
requested entry/history. The adapter builds a UUID index once and maps references from that same inspection,
instead of combining fresh entries with cached catalogs from another revision.
It generation-checks the mapped result before returning it. Lock clears the
application catalog together with the session.

The picker updates only the editing draft. Image import reads and decodes off
the main thread, limits source size to 20 MiB and dimensions to 16,384 per side
and 40 million pixels, and normalizes to a PNG thumbnail at most 128 pixels.
Import completion is bound to an editor token captured when the native picker
opens, and is discarded after Cancel, Save, a new choice or disappearance.
The core accepts PNG imports up to 1 MiB, validates selected IDs before mutation,
and commits changes through existing history tracking. Equal imported bytes
reuse an existing asset without changing its UUID/name; retained history and
other owners keep their assets. Group icon editing is not exposed.

[FaviconDownloader](../KeeLocker/Data/macOS/FaviconDownloader.swift) is an injected
Swift networking service, independent of Rust and vault credentials. It requests
only a sanitized HTTPS origin, scans bounded HTML once with cancellation checks,
examines up to 32 advertised links, tries five
with larger/touch icons preferred, and falls back to `/favicon.ico`.
Redirects must remain HTTPS without URL credentials
and are capped at three per request. Ephemeral sessions disable cookies,
credential storage and disk cache; streamed responses are capped at 1 MiB for
HTML and 4 MiB for images, with request/resource timeouts. Existing image limits
and PNG normalization apply off the main thread. Multi-size ICO images use their largest valid representation;
animated images use the first frame. HTTP Websites are attempted
over HTTPS; no insecure fallback or external favicon service is used.

Manual downloads reuse the editor import generation: Cancel, Save, a different
choice, Website changes or disappearance invalidate their results. They remain
drafts until Save. The global `automaticallyDownloadWebsiteIcons` preference is
off by default; RootView binds it to VaultStore. Enabling it or applying a vault
starts a serial queue for entries with standard icon 0 (or an unassigned default
key), and for downloaded icons whose saved origin differs from the current
Website origin. Path/query/fragment changes within one origin do not refresh.
Explicit icon choices, including standard key 0, suppress automatic replacement
across URL changes and reopened sessions. Their current built-in ID or custom
UUID is stored under `KeeLocker.Icon.Manual` in encrypted entry CustomData. The
marker is trusted only when it matches the current icon, is preserved by unrelated
edits and is cleared by a website download. Other standard IDs and custom images
without website provenance are preserved as well.

Both manual and automatic website downloads save the sanitized origin and the
resolved custom icon UUID in encrypted entry CustomData under
`KeeLocker.WebsiteIcon.Origin` and `KeeLocker.WebsiteIcon.UUID`. Unrelated edits
preserve these values, including a changed Website awaiting refresh. Choosing a
standard/custom icon or importing a file clears them. The mapping trusts origin
metadata only when its UUID matches the current icon, so another client's icon
change invalidates stale provenance. History retains each version's provenance
with its image. Existing custom icons without provenance remain fixed; Download
from website associates the new image with the Website for future changes.

Automatic requests leave the UI usable, pause during drafts or history inspection,
and defer during busy/dirty state, pending refresh or an operation failure. Before
mutation, the store reserves the busy slot, obtains a complete current entry and
rechecks the session, preference generation, snapshot revision, Website and icon
eligibility. It then runs the existing update command, retaining history, autosave,
backup and conflict behavior. A save already admitted can finish after revocation.
Candidate queues are built once per snapshot; failed origins skip remaining
entries directly rather than repeatedly scanning and normalizing the whole vault.
Temporary busy/refresh guards retain the candidate and resume from its cached
download even when the refresh reports no changed snapshot.
Obsolete/detail-read attempts suppress retries only for their snapshot, so an
external edit cannot permanently block a later return to the same Website.
Successful attempts must not block that return either; persisted origin controls
eligibility. One result per origin (including failure) is reused during the session; failed
sites are retried on re-enable or a new session. Lock/replacement clears all
download caches, origins and attempt metadata. Nothing is written to preferences
except the boolean; networking errors are quiet in automatic mode, while save
failures use the normal unsaved warning.

## Attachment export

Attachment export uses `AttachmentExport` outside the repository's encrypted
save path. It writes private plaintext staging files off the main thread and
publishes with an exclusive hard link: existing files, symlinks and hard links
are never replaced, including after a native Replace confirmation. It also
rejects the active vault pathname, its `.bak`, the configured backup directory
(the app uses Application Support) and the sibling `.keelocker-backups` tree
when the destination is absent. Checks use the opened destination directory,
canonical paths and the volume's case sensitivity. Picker completion, attachment
reads and export errors remain bound to the originating session and inspection.
The sheet explains that export requires a new filename.

## Clipboard lifetime

[ClipboardOwner](../KeeLocker/Data/macOS/ClipboardOwner.swift) owns the most
recent value copied by KeeLocker through the pasteboard change count; it retains
no copy of that value. When clipboard clearing is enabled, it clears that owned
value after the timeout or confirmed application termination. Recheck ownership
and the preference when clearing. A cancelled Quit keeps the pending cleanup;
another application's clipboard write must survive both timeout and termination.

## External changes and conflicts

The monitor watches both the directory and current file because atomic saves replace the inode; it also checks on app activation. Notifications are debounced. The store defers refresh while busy, dirty, editing a draft or inspecting history/attachments.

Installing a watcher schedules an initial refresh, closing the gap between file
loading and observation, including time spent awaiting Touch ID enrollment.
That refresh obeys the same draft, busy and dirty deferral rules.

Rust compares the source hash and decrypts changed files before adopting them. A successful refresh retains valid selection, search/group scope and collapse state. Changed credentials require a fresh Lock/Unlock. Failed reloads retain the previous session and edits.

Conflicts offer Save Copy or explicit Reload Latest; the latter discards local changes only after successfully reading the external file. Save As refuses an existing different destination and moves monitoring to the new path. Do not replace this behavior with unconditional overwrite or automatic merge.

## Safe-save contract

Read [io.rs](../crates/keelocker-core/src/kdbx/io.rs) and [roundtrip.rs](../crates/keelocker-core/src/kdbx/roundtrip.rs) before changing saving:

1. Serialize with fresh library-generated encryption parameters, reopen and compare the complete model, including protected values, history and attachment bytes.
2. Write only encrypted bytes to a private temporary file in the destination directory and sync it.
3. For the opened file, verify its expected hash, preserve the pinned encrypted original and a versioned recovery copy, sync the backup directory, create an encrypted `.bak`, recheck the source and atomically replace it. Required backup failure leaves the source unchanged. For a new destination, refuse replacement.
4. Sync the directory. Once replacement commits, adopt the written path/hash even if directory sync fails. Keep the session dirty and report the durability failure so Save can retry without conflicting with KeeLocker's own bytes. Save As must also retain its committed destination.

Saving upgrades supported older databases to KDBX 4.1 while retaining cipher/KDF settings. Unknown structures the writer cannot preserve are rejected conservatively. History and shared attachment ownership must survive changes even when the UI does not expose those values.

Performance improvements reuse the KDF output only for validation of the bytes produced by that save. Header/payload authentication, decryption and complete model comparison still run. Each session prepares one future save in the background with a fresh KDF salt and unchanged database parameters. The save waits if its preparation is unfinished; preparations are consumed once, including failures, and their derived keys are zeroized after validation. Nothing is shared between vaults or persisted outside the KDBX. Keep validation and KDF strength intact; inspect the [vendor patch rationale](../vendor/keepass/KEELOCKER-PATCH.md) before modifying this path.

Opening decrypts once, sharing that payload between compatibility checks and XML
parsing. Attachment validation hashes bytes directly. Complete-model comparison
normalizes derived binary IDs and history-parent references without dropping
history or shared attachment bytes.

Clean Save checks the current source identity/hash but does not serialize,
replace the file or rotate backups. An outstanding post-commit durability
warning remains dirty and must still be retried.

Production supplies the local Application Support backup root through
`VaultStore` and the Rust adapter, for both password and cached-key opens.
`CoreVault.configure_backup_directory` configures only the session; opening
does not create backups. Direct core callers without a configured root use
`.keelocker-backups` beside the source. A hash of the canonical path selects the
vault namespace; no plaintext manifest or credentials are stored.
The first accepted source is pinned as `original.kdbx`. Recovery generations
retain the latest 20 versions plus a daily version for 30 days; pruning happens
after commit and excludes the original and unrecognized files. Backups are
deduplicated only against the newest generation on the same UTC day; reaccepted
earlier ciphertext gets a fresh timestamp so rotation preserves the current
save's source. New generation timestamps advance monotonically across backward
clock changes. Existing-generation hashing uses the same metadata/streaming
size bounds as recovery reads. Encrypted byte copies are published without
replacing existing snapshots, in
private directories with private file permissions. Save As to a new filename
preserves its source; later replacements use the destination's own namespace.

There is no multi-writer transaction: a small hash-check/rename race remains.
Directory-sync failure can report failure after rename, and existing ACLs/extended
attributes are not copied. Local recovery copies share the host's disk failure
risk; keep independent backups.

File/key-file reads and library decryption are bounded before expensive work.
Scoped library limits check imported KDF costs before deriving a key and bound
decompressed payloads before XML parsing. Exceeding a supported bound rejects
the file; imported cryptographic parameters are never silently reduced. Apply
the same bounds on reload and cached-key open. Mutations that cannot be reopened
within the safety limits must fail before the destination is replaced.

## Recovery copies

Recovery runs through the repository boundary even when password unlock fails.
The adapter freezes the canonical source identity before the first unlock or
recovery request, including when the selected path is an alias. It retains that
identity after failed decryption and ignores later alias retargeting.
The Rust recovery handle captures the source's namespace identity and the
configured backup root without reading its plaintext or creating directories.
Listing accepts only the pinned original and recognized digest-verified
generations in that namespace; selection tokens bind the chosen bytes.
Restore validates the selected version with the supplied password/key file
using the normal bounded KDBX parser. It publishes the exact encrypted bytes
to a new destination with no-clobber semantics, syncs the file and directory,
and returns the committed path with a separate durability flag.
It never replaces the current source or session, clears dirty edits, prunes
copies or updates the remembered vault path. Existing destinations are conflicts.

The native sheet uses application `VaultBackup`/`VaultRecoveryResult` models.
The store pauses automatic mutations and refresh while inspecting copies,
reserves busy state during recovery and rechecks its session after each await.
Open/Lock/session replacement invalidates late results and native file-dialog
callbacks. Password input remains ephemeral; it is not logged or persisted.

## Format preservation

Unknown XML extensions/attributes, duplicate keys/UUIDs, unsupported KDF fields
and nonempty KDBX4 header comments are rejected rather than silently discarded.
Arbitrary standard CustomData values are retained. These guards conservatively
reject some valid third-party extensions.

Preserve text content and leading/trailing whitespace in credential, custom
field and CustomData values. Ignore structural XML indentation separately.
Attribute-bearing blank `Value` elements must survive parsing in current and
historical entries. Their restoration uses the existing XML reader and scalar
decoder before `xml_to_db`; keep decoding and protection handling consistent
with the normal parser. Repeated unrelated saves must retain those values.
Tags are structured lists; a whitespace-only Tags element normalizes to no tags.

Live OTP generation accepts only `otpauth://totp` fields. HOTP and unknown URI
hosts are unsupported for display, but their raw custom fields must survive
editing and saves without being rewritten as TOTP.

Loading or saving alone must not prune history. Entry mutations honor the
database's history item/size limits and rebuild attachment/icon ownership before
removing discarded assets; data still referenced by retained history, another
entry or a group must survive.
Size limits count serialized payload bytes: UTF-8 text and padded-base64 text
for binary CustomData, plus each version's attachment bytes.

KDBX3.1 requires an embedded HeaderHash. Verify it before parsing protected
fields and remove it during the KDBX4.1 upgrade. Malformed numeric header values
return safe errors. Parser panics are contained before they can poison an open
session; failed reloads retain unsaved data for Save Copy. Authentication damage
can still be indistinguishable from wrong credentials, including KDBX3 padding
failure.

## Reuse or replace the backend

The Rust crate exports a library and contains no macOS UI dependencies. Extraction must carry the workspace's `vendor/keepass` patch and tests/fixtures. macOS is the current app platform, with no iOS, Android or Windows app targets; future platform organization is undecided. An iOS client could share Swift code, but build scripts and checked-in bindings currently target macOS/Swift. Additional hosts need packaging and filesystem verification. The current API accepts filesystem paths, so document providers may need a storage abstraction. File observation and biometric authentication belong to the host application.

A Swift replacement can implement `VaultRepository` and be selected in `VaultStore.openFile` without changing screens. Preserve capabilities, error mapping, redaction, async behavior and persistence/conflict semantics. Most migration work would be implementing and verifying equivalent KDBX behavior, not rewiring SwiftUI. Separate presentation properties from application models if extracting those models as a reusable package.
