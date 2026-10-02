# KeeLocker agent instructions

> KeeLocker opens and edits existing password vaults while preserving their data and compatibility with other KeePass clients.

## Critical rules

- Preserve the existing native macOS design. Change layout, colors, typography or toolbar structure only when the task explicitly calls for it; follow [DESIGN.md](DESIGN.md) for UI work.
- Keep the boundary `SwiftUI → VaultStore → VaultRepository`. Confine Rust DTOs and UniFFI calls to `KeeLocker/Data/Rust`; give views application models and capabilities rather than concrete repository checks.
- Use the existing `keepass` library for KDBX parsing, encryption and KDFs. Preserve the workspace's vendored patch; read its rationale before changing or replacing it.
- Keep file/crypto work off the main thread. Bind asynchronous results and delayed dialogs to their originating session; cancellation alone does not stop a Rust call.
- Use synthetic vaults and temporary copies for tests and manual checks. Keep real passwords, key files, decrypted data and user vaults out of logs, preferences, fixtures and commits. The remembered vault path is the intended preferences exception.
- Retain save validation, conflict checks and encrypted backups. Recover conflicts through Save Copy or an explicit reload; never silently overwrite another client's changes.
- New items remain drafts until Save. Existing mutation commands autosave through the repository adapter; report persistence failures without dropping the in-memory edit.
- Keep `MemoryVaultRepository` functional. Lock must clear decrypted application state and release the persistent session.
- Update this file and the relevant topic document in the same change when boundaries, commands or invariants change. Dependency versions belong in manifests; verification results belong in the change report.

## Commands

Run from the repository root. Build and Swift tests require the macOS/Xcode/Rust setup described in [README.md](README.md#build). These commands write build artifacts, not user vaults. Apply any host-required command wrapper, such as RTK.

```sh
cargo test --locked -p keelocker-core
cargo fmt --all -- --check
cargo clippy --locked -p keelocker-core --all-targets -- -D warnings
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
