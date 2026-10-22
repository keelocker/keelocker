# KeeLocker agent instructions

> KeeLocker opens and edits existing password vaults while preserving their data and compatibility with other KeePass clients.

## Critical rules

- Preserve the existing native macOS design. Change layout, colors, typography or toolbar structure only when the task explicitly calls for it; follow [DESIGN.md](DESIGN.md) for UI work.
- Keep the boundary `SwiftUI → VaultStore → VaultRepository`. Confine Rust DTOs and UniFFI calls to `KeeLocker/Data/Rust`; give views application models and capabilities rather than concrete repository checks.
- Use the existing `keepass` library for KDBX parsing, encryption and KDFs. Preserve the workspace's vendored patch; read its rationale before changing or replacing it.
- Keep file/crypto work off the main thread. Bind asynchronous results and delayed dialogs to their originating session; cancellation alone does not stop a Rust call. Verify the opened vault descriptor matches the captured canonical path before and after reading. Admit one open per canonical path across adapters, coalesce waiting retries and release admission only after late-session cleanup.
- Use synthetic vaults and temporary copies for tests and manual checks. Keep real passwords, key files, decrypted data and user vaults out of logs, preferences, fixtures and commits. The remembered vault path is the intended preferences exception.
- Retain save validation, conflict checks and encrypted backups. Preserve the pinned original and versioned recovery files before replacing a vault; backup failure must retain the source and dirty edit. Clean Save must preserve file bytes and backups. Adopt a committed save's path/hash even if directory sync fails, retaining the unsaved warning for retry. Recover conflicts through Save Copy or an explicit reload; never silently overwrite another client's changes.
- Apply bounded file/key-file reads and the library's scoped KDF/decompression limits before expensive work. Reject unsupported costs without lowering imported cryptographic settings. Keep failure injection confined to Rust test builds.
- Require the authenticated KDBX4 end-of-stream block on open and reload. Bound attachment imports to 64 MiB using regular-file descriptors and incremental reads before passing bytes to the repository.
- Export attachments only to new files, with private staging and exclusive publication. Reject the active vault path, its `.bak` and owned recovery directories even when the destination is absent. Bind export results and errors to the originating session and inspection.
- New items remain drafts until Save. Existing mutation commands autosave through the repository adapter; report persistence failures without dropping the in-memory edit.
- Honor the imported recycle-bin setting. Move enabled deletions into the bin; use an explicit confirmed command for permanent deletion there. Exclude its descendants from active lists and automatic mutations. Trash/Restore change location without history checkpoints or retention pruning; preserve UUID/history/assets and fall back to the root if the old parent no longer exists.
- Recovery lists only owned encrypted copies and validates the selected copy with its own credentials before publishing a new file. Keep it available after failed unlock; bind dialogs/results to their originating session and retain the current vault, dirty edits and all backups. Never overwrite an existing recovery destination.
- Entry icon choices and image imports remain in the editing draft until Save. Keep standard KDBX IDs and custom UUIDs separate from SF Symbol presentation; preserve unknown IDs on unrelated edits. Read detail/history and their group/icon catalogs atomically in Rust. Persist explicit manual icon identity in encrypted CustomData so automatic downloads preserve even standard key choices across URL edits/reopen. Keep catalogs session-scoped, generation-check import results, normalize images off the main thread and use existing history/ownership tracking.
- Website icon networking requires a manual download or the opt-in automatic preference. Strip stored URL credentials/path/query and use bounded ephemeral HTTPS requests. Persist downloaded icon origin and matching UUID only in encrypted entry CustomData; refresh on origin changes, preserve manual choices and ignore provenance whose UUID no longer matches. Manual results belong to the originating draft; automatic mutations must wait for busy/draft/dirty/history guards, fetch complete current entries, recheck Website/icon eligibility and use the normal save/conflict path. Lock or preference revocation must discard late results and clear download caches.
- Keep `MemoryVaultRepository` functional. Lock must clear decrypted application state and release the persistent session.
- Preserve whitespace in stored text and honor imported history limits on mutation; prune assets only after rebuilding all ownership. Refresh history inspections on snapshot revision, not count or timestamps. Keep raw draft tags until Save. Monitor installation must request a session-bound refresh with the existing busy/draft guards. Clear only KeeLocker's owned clipboard value on timeout or confirmed Quit when enabled.
- Prepare Touch ID automatically after a successful password unlock when supported; skip unavailable hardware and preserve password access on enrollment failure. Keep it session-only: encrypted normalized key material in RAM, biometric Secure Enclave recovery, and cache clearing on Quit. Bind enrollment/reopen to the opened canonical path; capture an enrollment revision before password load, reserve before key export, and invalidate only the failing session's registration. Match the opened vault's immutable canonical identity and recheck the registration after biometric KDBX open; close mismatched or revoked sessions. Keep native authentication behind the injected Quick Unlock service; cancel, finish and generation-check every request.
- Update this file and the relevant topic document in the same change when boundaries, commands or invariants change. Dependency versions belong in manifests; verification results belong in the change report.

## Commands

Run from the repository root. Build and Swift tests require the macOS/Xcode/Rust setup described in [README.md](README.md#build). These commands write build artifacts, not user vaults. Apply any host-required command wrapper, such as RTK.

```sh
cargo test --locked -p keelocker-core
cargo fmt --all -- --check
cargo clippy --locked -p keelocker-core --all-targets -- -D warnings
bash scripts/check-bindings.sh
python3 scripts/generate-notices.py --check
bash scripts/release.sh preflight
xcodebuild -project KeeLocker.xcodeproj -scheme KeeLocker -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/keelocker-derived build
xcodebuild -project KeeLocker.xcodeproj -scheme KeeLocker -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/keelocker-derived -only-testing:KeeLockerTests test
```

For Intel use the matching Xcode architecture and Rust target; Intel runtime is unverified. For UI or file-format changes, follow the additional checks in the development guide rather than treating these commands as complete coverage.

## Documentation routes

Read the relevant topic before modifying its code; there is no need to load the full library for every task.

| Task | Read |
| --- | --- |
| Find ownership, change state/repositories, reuse or replace the core | [Architecture and invariants](docs/architecture.md) |
| Choose tests, change exported Rust APIs, regenerate bindings, profile saves | [Development and verification](docs/development.md) |
| Check supported behavior and known format/save limitations | [README.md](README.md#supported-behavior), [safe save](README.md#safe-save-and-limitations) |
| Change upstream parsing, serialization or attachment ownership | [Vendored patch rationale](vendor/keepass/KEELOCKER-PATCH.md), Rust regression tests |
| Add or regenerate synthetic vault fixtures | [Fixture provenance](KeeLockerTests/Fixtures/README.md) |
| Change UI deliberately | [DESIGN.md](DESIGN.md), existing views and UI tests |
| Change Touch ID, cached key material or authentication lifetime | [Session Quick Unlock](docs/touch-id.md), [QuickUnlockTests.swift](KeeLockerTests/QuickUnlockTests.swift) |
| Change dependencies, license notices or contribution/security policy | [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), [notice provenance](licenses/README.md), development guide |
| Build a release DMG, publish assets or verify installation | [Release procedure](docs/release.md), [release workflow](.github/workflows/release.yml) |
