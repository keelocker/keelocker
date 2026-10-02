# Development and verification

## Build setup and side effects

Run commands from the repository root. See [README build prerequisites](../README.md#build) and the manifests for toolchain/dependency requirements. The checked-in Xcode scheme is `KeeLocker`; unit/bridge and UI tests are separate targets.

The Xcode phase invokes [build-rust.sh](../scripts/build-rust.sh), which runs a locked release Cargo build for each Xcode architecture and combines static libraries. Cargo outputs go to `target`; Xcode outputs go to the supplied DerivedData directory. Even a Debug app uses the Rust release library. An Apple Silicon destination needs the `aarch64-apple-darwin` Rust target; universal builds also need `x86_64-apple-darwin`.

Use the focused commands in `AGENTS.md` first, then add the checks warranted by the changed behavior. Read-only documentation changes need link/path/command inspection, not an application rebuild.

## Choose verification by changed behavior

| Change | Required evidence |
| --- | --- |
| Store state, drafts, selection, capabilities or async lifecycle | Swift unit/store tests in [VaultStoreTests.swift](../KeeLockerTests/VaultStoreTests.swift); retain demo behavior and exercise delayed results around Lock/session replacement. |
| Swift adapter, favorites, autosave or file monitoring | Swift bridge tests plus Rust tests; use temporary files to check save/reopen, external atomic and in-place writes, conflicts and Save As. |
| Rust commands, mapping, save, parser or vendor patch | Rust regressions plus independent KeePassXC interoperability; run Clippy/format checks. Verify preservation of data the UI does not edit. |
| Exported Rust API or DTO | Regenerate all UniFFI artifacts, build the app and run Swift bridge tests as well as Rust tests. |
| UI interaction or hierarchy | Swift tests and focused UI/manual checks on the existing design. Report native picker/focus/layout behavior separately from unit coverage. |
| Save performance | Release timing on synthetic fixtures; retain independent reopen/interop checks and current KDF settings. |

Rust tests are split between [lifecycle.rs](../crates/keelocker-core/tests/lifecycle.rs), [review_safety.rs](../crates/keelocker-core/tests/review_safety.rs) and [review_attachments.rs](../crates/keelocker-core/tests/review_attachments.rs). The vendor patch document names the upstream invariants these regressions protect.

## KeePassXC interoperability

Normal `cargo test` skips the ignored KeePassXC and timing tests. With KeePassXC CLI installed, run the functional suite including interoperability, excluding manual benchmarks:

```sh
cargo test --locked -p keelocker-core -- --include-ignored --skip save_timing --skip operation_timing
```

The default CLI path is `/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli`; set `KEEPASSXC_CLI` to the executable if installed elsewhere. The matrix covers KDBX 4.0/4.1, Argon2d/id, AES/ChaCha20 and password with/without a key file. Separate synthetic 3.1 imports cover legacy reads. These checks independently reopen output; same-library round trips alone are insufficient evidence for writer changes.

Tests use temporary directories. Existing fixture credentials are public and artificial; see [fixture provenance](../KeeLockerTests/Fixtures/README.md). Do not set `KEELOCKER_MATRIX_OUTPUT` during routine tests: that variable intentionally writes regenerated fixtures to its target. Regenerate fixtures only as part of a fixture change and inspect the diff/provenance.

## UniFFI generation

The source of truth is the exported Rust API in [vault/mod.rs](../crates/keelocker-core/src/vault/mod.rs), [models/mod.rs](../crates/keelocker-core/src/models/mod.rs), [error.rs](../crates/keelocker-core/src/error.rs) and the pinned manifests. Do not hand-edit the generated Swift, C header or module map.

After changing the exported API, run:

```sh
bash scripts/generate-bindings.sh
git diff -- KeeLocker/Data/Rust/Generated
```

The script builds the host library and generator, writes all three files in `KeeLocker/Data/Rust/Generated`, and renames the module map to the name Xcode uses. Review and commit generated changes alongside their source. If the API did not change, regeneration should leave these files identical. Recheck under the same locked toolchain when investigating unexpected generated drift.

For changes to the underlying `keepass` dependency, inspect the workspace `[patch.crates-io]` and [KEELOCKER-PATCH.md](../vendor/keepass/KEELOCKER-PATCH.md) before upgrading. Reconcile local preservation/security/performance fixes and rerun their regressions and interoperability checks.

## Native UI checks

Run the UI target explicitly when relevant:

```sh
xcodebuild -project KeeLocker.xcodeproj -scheme KeeLocker -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/keelocker-derived -only-testing:KeeLockerUITests test
```

The [UI tests](../KeeLockerUITests/ToolbarHoverUITests.swift) contain toolbar and real-file scenarios. XCTest needs host automation support; a runner authentication/initialization failure is a coverage gap, not a pass or proof of an application defect. Report it and use focused manual checks where available.

For a manual launch, `--demo-vault` opens the memory demo and `--ignore-last-vault` avoids reopening the remembered path. Use a temporary copy for real-file checks and do not overwrite the user's app or vault to isolate verification.

A useful real-file smoke check is: open/unlock → select/search actual entries → create a draft inside a group → cancel without a file change → Save a draft and independently reopen → edit externally in KeePassXC and observe reload → edit/save again → exercise conflict recovery if changed → Lock and check that entries/details clear. Verify UI-specific scope/focus behavior only when it is relevant to the change.

## Performance checks

```sh
cargo test --locked --release -p keelocker-core operation_timing -- --ignored --nocapture
```

The benchmark covers open, snapshots and saves for Argon2id, AES-KDF, a large attachment and a large entry list. It measures both an immediate save and a save after an editing pause, since future KDF preparation can still be running just after unlock. Timing output is diagnostic, not a portable CI threshold.

Keep the database's KDF configuration unchanged when comparing results. Do not trade away save validation, backup creation or conflict checks for lower timings; optimize duplicate work and projections instead.

## Report verification accurately

List the commands actually run and their outcomes, including skipped interoperability or blocked UI coverage. Distinguish automated tests, a successful build and manual observations. Historical counts/timings in README describe earlier verification; they do not prove the current checkout passed.

When changing persistence, report any remaining failure/recovery behavior. Update architecture or workflow documents when their described contract changes; avoid adding per-run test counts or machine-specific paths to agent instructions.
