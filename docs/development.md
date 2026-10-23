# Development and verification

## Build setup and side effects

Run commands from the repository root. See [README build prerequisites](../README.md#build) and the manifests for toolchain/dependency requirements. The checked-in Xcode scheme is `KeeLocker`; unit/bridge and UI tests are separate targets.

The Xcode phase invokes [build-rust.sh](../scripts/build-rust.sh), which runs a locked release Cargo build for each Xcode architecture and combines static libraries. Cargo outputs go to `target`; Xcode outputs go to the supplied DerivedData directory. Even a Debug app uses the Rust release library. An Apple Silicon destination needs the `aarch64-apple-darwin` Rust target; universal builds also need `x86_64-apple-darwin`.

Use the focused commands in `AGENTS.md` first, then add the checks warranted by the changed behavior. Documentation changes need link/path/command inspection, not an application rebuild.

## Continuous integration

[CI](../.github/workflows/ci.yml) runs locked Rust tests with all features on the
MSRV declared in the crate manifest and on stable Rust, including compilation
of the binding generator. Stable also runs formatting and Clippy across all
targets/features with warnings denied. A separate Linux job installs KeePassXC and includes the
ignored interoperability tests, excluding the manual timing tests. Missing CLI
tools or failing interoperability fail the job.

The stable Rust job fetches locked dependency sources and checks the generated
third-party notices. Stale or missing notice output fails CI.

The Apple Silicon macOS job selects an explicit Xcode installation, checks
generated bindings, runs Rust tests on the native filesystem, builds the app and runs `KeeLockerTests`. `KeeLockerUITests`
and native fingerprint authentication require host automation/hardware support
and are outside the hosted workflow. A green unit-test job does not prove those
checks passed.

Actions use full commit SHA pins and a read-only repository token. No signing,
publishing or release credentials are needed. Dependencies resolve through
`Cargo.lock`; the MSRV comes from the manifest. Stable Rust, hosted runner images
and distribution packages can change, so job logs identify the actual tools and
do not imply a byte-for-byte reproducible environment.

## Choose verification by changed behavior

| Change | Required evidence |
| --- | --- |
| Store state, drafts, selection, capabilities or async lifecycle | Swift unit/store tests in [VaultStoreTests.swift](../KeeLockerTests/VaultStoreTests.swift); retain demo behavior and exercise delayed results around Lock/session replacement. |
| Clipboard ownership or cleanup | [ClipboardTests.swift](../KeeLockerTests/ClipboardTests.swift); use a uniquely named synthetic pasteboard, exercise timeout and confirmed/cancelled termination, and preserve another writer's clipboard value. |
| Attachment export | [AttachmentExportTests.swift](../KeeLockerTests/AttachmentExportTests.swift); preserve existing vaults, backups, ordinary files and symlink/hardlink destinations, reject absent protected paths and backup-directory aliases, and verify new plaintext exports with private permissions. Check native destination errors and obsolete-session error suppression separately. |
| Swift adapter, favorites, autosave or file monitoring | Swift bridge tests plus Rust tests; use temporary files to check save/reopen, external atomic and in-place writes, conflicts and Save As. |
| Recovery copies or recycle-bin behavior | Rust recovery/recycle regressions, independent KeePassXC reopen, Swift `RecoveryTests` and recycle tests; run the focused native recovery/recycle UI flow. Preserve dirty edits and test failed unlock, stale selection, existing destinations and permanent-delete confirmation. |
| Rust commands, mapping, save, parser or vendor patch | Rust regressions plus independent KeePassXC interoperability; run Clippy/format checks. Verify preservation of data the UI does not edit. |
| Exported Rust API or DTO | Regenerate all UniFFI artifacts, build the app and run Swift bridge tests as well as Rust tests. |
| UI interaction or hierarchy | Swift tests and focused UI/manual checks on the existing design. Report native picker/focus/layout behavior separately from unit coverage. |
| Save performance | Release timing on synthetic fixtures; retain independent reopen/interop checks and current KDF settings. |
| Touch ID or key material | Run `QuickUnlockTests` and Rust `session_key_material_*` regressions, regenerate bindings for exported API changes, and verify the native biometric boundary separately on a Touch ID Mac. |

Rust regressions live in the [integration test directory](../crates/keelocker-core/tests)
and inline unit-test modules. Persistence fault injection belongs beside the
save implementation so production APIs do not expose test controls. The vendor
patch document names the upstream invariants these regressions protect.

Backup and persistence regressions use synthetic files in private temporary
directories. Exercise failures before commit, post-commit warnings, external
replacement and recovery from pinned/versioned copies. Abrupt subprocess exit
tests model process termination without cleanup; injected disk-full errors
model failing writes. These do not simulate a power cut or prove filesystem
durability on every storage provider. Keep test controls behind `cfg(test)`;
production must not read failure-injection environment variables.

## KeePassXC interoperability

Normal `cargo test` skips the ignored KeePassXC and timing tests. With KeePassXC CLI installed, run the functional suite including interoperability, excluding manual benchmarks:

```sh
cargo test --locked -p keelocker-core -- --include-ignored --skip save_timing --skip operation_timing
```

The default CLI path is `/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli`; set `KEEPASSXC_CLI` to the executable if installed elsewhere. The matrix covers KDBX 4.0/4.1, Argon2d/id, AES/ChaCha20 and password with/without a key file. It edits/saves after reopening with session key material, then independently exports the output with KeePassXC. Separate synthetic 3.1 imports cover legacy reads. Additional interoperability regressions cover preserved whitespace and pruned history with shared attachments. Run across all core test targets so new ignored interoperability cases are included. Same-library round trips alone are insufficient evidence for writer changes.

Tests use temporary directories. Existing fixture credentials are public and artificial; see [fixture provenance](../KeeLockerTests/Fixtures/README.md). Do not set `KEELOCKER_MATRIX_OUTPUT` during routine tests: that variable intentionally writes regenerated fixtures to its target. Regenerate fixtures only as part of a fixture change and inspect the diff/provenance.

## UniFFI generation

The source of truth is the exported Rust API in [vault/mod.rs](../crates/keelocker-core/src/vault/mod.rs), [models/mod.rs](../crates/keelocker-core/src/models/mod.rs), [error.rs](../crates/keelocker-core/src/error.rs) and the pinned manifests. Do not hand-edit the generated Swift, C header or module map.

After changing the exported API, run:

```sh
bash scripts/generate-bindings.sh
git diff -- KeeLocker/Data/Rust/Generated
```

The script builds the host library and generator, writes all three files in `KeeLocker/Data/Rust/Generated`, and renames the module map to the name Xcode uses. Review and commit generated changes alongside their source. If the API did not change, regeneration should leave these files identical. Recheck under the same locked toolchain when investigating unexpected generated drift.

To verify without changing committed files, run:

```sh
bash scripts/check-bindings.sh
```

The checker supports macOS and Linux, builds with `--locked`, generates into a
temporary directory and compares the complete output directory. A missing,
extra or changed artifact fails the check. It respects `CARGO_TARGET_DIR` and
removes its temporary output on exit. The write-in-place generation script
currently uses the macOS library path.

For changes to the underlying `keepass` dependency, inspect the workspace `[patch.crates-io]` and [KEELOCKER-PATCH.md](../vendor/keepass/KEELOCKER-PATCH.md) before upgrading. Reconcile local preservation/security/performance fixes and rerun their regressions and interoperability checks.

## Third-party notices

[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) is generated from the locked
Cargo dependency graph, including binding-generation and other-platform
dependencies. Python 3 and cached Cargo sources are required. After a dependency
or lockfile change, run:

```sh
cargo fetch --locked
python3 scripts/generate-notices.py
python3 scripts/generate-notices.py --check
```

[generate-notices.py](../scripts/generate-notices.py) uses locked, offline Cargo
metadata with the `bindings` feature and collects dependency license/notice
texts. The repository includes an official MPL text fallback for UniFFI
archives without license files and package-specific fallback notices; see their
[provenance](../licenses/README.md). Missing license text fails generation. Review
the generated artifact alongside manifest/lockfile changes, preserving the
vendored library's license and the terms for UniFFI runtime/template code in
generated bindings. Do not hand-edit the notice inventory.

The Xcode resources include the root `LICENSE` and `THIRD_PARTY_NOTICES.md`.
Keep those distribution notices included when changing app packaging.

## Native UI checks

Run the UI target explicitly when relevant:

```sh
xcodebuild -project KeeLocker.xcodeproj -scheme KeeLocker -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/keelocker-derived -only-testing:KeeLockerUITests test
```

The [UI tests](../KeeLockerUITests/ToolbarHoverUITests.swift) contain toolbar and real-file scenarios. XCTest needs host automation support; a runner authentication/initialization failure is a coverage gap, not a pass or proof of an application defect. Report it and use focused manual checks where available.

For a manual launch, `--demo-vault` opens the memory demo and `--ignore-last-vault` avoids reopening the remembered path. Use a temporary copy for real-file checks and do not overwrite the user's app or vault to isolate verification. File UI tests also pass `--disable-touch-id` to inject no biometric service and avoid human-only enrollment prompts; default behavior is covered by the injected service tests.

For Touch ID, use a synthetic fixture: password unlock → confirm automatic enrollment
biometrics → Lock → Touch ID unlock → edit/save and independently reopen → Lock
and cancel Touch ID → check password fallback → Quit/relaunch and check
that the password is required. Check key-file vaults and delayed results after
Lock or switching files. XCTest uses injected synthetic storage and does not
simulate a real fingerprint. On the native boundary, a private-key operation
with `LAContext.interactionNotAllowed` must fail; do not replace the protected
operation with a software `evaluatePolicy` gate. macOS/Xcode sandbox restrictions
can block the macro server, XCTest or authentication services; report actual
coverage and use host-approved execution for these native checks.

A useful real-file smoke check is: open/unlock → select/search actual entries → create a draft inside a group → cancel without a file change → Save a draft and independently reopen → edit externally in KeePassXC and observe reload → edit/save again → exercise conflict recovery if changed → Lock and check that entries/details clear. Verify UI-specific scope/focus behavior only when it is relevant to the change.

`testRecoveryCopyAndRecycleBinNativeFlow` and its `Dark` variant use temporary
synthetic fixtures: delete into Recycle Bin, cancel permanent deletion without a
file change, Restore to the previous group, verify with KeePassXC, then restore
the pinned original to a new file through Recovery Copies. They capture normal
and restored-copy screenshots in both appearances. Scope context-menu actions
to the app window and confirmation buttons to the alert so menu-bar/Touch Bar
duplicates do not make XCTest queries ambiguous.
Manually inspect the recovery sheet at minimum window size; a successful drag
gesture alone does not prove the window resized. Confirm keyboard dismissal,
password/key-file selection and visible
error/committed-copy status. Native picker/XCTest initialization failures are
coverage gaps; report them separately from successful unit and bridge tests.

## Entry icon checks

Rust lifecycle tests cover icon selection/import, duplicate image reuse, invalid
selection atomicity, unknown stored IDs, retained history and shared owners.
The ignored `keepassxc_icon_changes_and_history_roundtrip` test independently
exports the modified vault through KeePassXC, including the embedded PNG and
historical standard icon. Run it with the functional interoperability suite above.

Swift tests cover the complete standard icon catalog, image normalization and
invalid input, demo draft cancellation, Save/reopen of a real synthetic vault,
history mapping, custom UUID reuse and catalog clearing on Lock. Delayed-loader
tests exercise cancelled/replaced import sessions and obsolete failure results
independently of native picker automation. Focused native UI tests are
`testEntryIconPickerSearchSaveAndCancel` and `testEntryIconImportCancelSaveAndReuse`.
Manually check the popover at normal/minimum window sizes and in both appearances;
the image picker should show a preview after selecting a file, and Cancel should
retain the prior icon. Imported image names/bytes must not be logged or persisted
outside the encrypted vault.

[FaviconTests.swift](../KeeLockerTests/FaviconTests.swift) injects synthetic
responses and delayed loaders rather than contacting account websites. It covers
origin sanitization, relative/cross-host icon discovery, HTTPS-only links,
fallback, invalid/oversized images and multi-size ICO quality, manual draft
invalidation, off-by-default automation,
origin reuse, Save/open scheduling and preference/session races. URL-change
regressions cover downloaded icons after Save/reopen, return to a cached origin,
manual choices clearing provenance and surviving URL changes/reopen (including
the standard key), unchanged origins, disabled downloads,
network failure retaining the old icon and obsolete refresh results. Rust
lifecycle regressions cover provenance/history preservation, mismatched external
icon UUIDs and KeePassXC retaining CustomData through an unrelated save.
`testDetailAndHistoryReadUseCatalogFromTheirOwnRevision` delays a synchronous
read until after an external custom-icon save and refresh, then verifies both
detail/history use the matching catalogs. Verify downloaded
icons through the existing synthetic KDBX bridge/reopen and KeePassXC checks.
Scale regressions exercise 4,000 custom references and 2,000 entries at a failed
origin; adversarial HTML regressions exercise long attributes and unfinished tags
within the response cap. These are coarse regression bounds, not portable
performance benchmarks. Retain the external-refresh/return-to-original-Website
scenario when changing automatic attempt/queue lifetimes.
Manually check Download from website with a public test site, change its domain
after Save with automation enabled and confirm the new icon, Cancel download,
draft Save/Cancel, and the Settings toggle in both appearances. Keep real vault
URLs and response bytes out of diagnostic logs and screenshots.

## Performance checks

```sh
cargo test --locked --release -p keelocker-core operation_timing -- --ignored --nocapture
```

The benchmark covers open, snapshots and saves for Argon2id, AES-KDF, a large attachment and a large entry list. It measures both an immediate save and a save after an editing pause, since future KDF preparation can still be running just after unlock. Timing output is diagnostic, not a portable CI threshold.

Keep the database's KDF configuration unchanged when comparing results. Do not trade away save validation, backup creation or conflict checks for lower timings; optimize duplicate work and projections instead.

## Report verification accurately

List the commands actually run and their outcomes, including skipped interoperability or blocked UI coverage. Distinguish automated tests, a successful build and manual observations. Workflow syntax validation does not prove remote CI ran successfully.

When changing persistence, report any remaining failure/recovery behavior. Update architecture or workflow documents when their described contract changes; avoid adding per-run test counts or machine-specific paths to agent instructions.
