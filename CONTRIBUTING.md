# Contributing

KeeLocker is in early development. Open an issue for a bug or proposed change,
or submit a focused pull request with its behavior, regression evidence and
remaining limitations. Report vulnerabilities through [SECURITY.md](SECURITY.md),
not a public issue containing exploit details or secrets.

## Development

Start with the [build setup](README.md#build), [architecture](docs/architecture.md)
and [verification guide](docs/development.md). Preserve the native macOS design
in [DESIGN.md](DESIGN.md) and the `SwiftUI → VaultStore → VaultRepository` boundary.
Keep Rust DTOs and UniFFI calls inside the Swift adapter. The in-memory demo must
continue to work.

Use synthetic vaults and temporary copies. Never attach real passwords, key
files, decrypted exports or user vaults to issues, logs, tests or commits.
Document fixture provenance and use artificial credentials when adding cases.

Run the relevant focused tests first, then the checks required by the change:

```sh
cargo test --locked -p keelocker-core
cargo fmt --all -- --check
cargo clippy --locked -p keelocker-core --all-targets -- -D warnings
bash scripts/check-bindings.sh
python3 scripts/generate-notices.py --check
xcodebuild -project KeeLocker.xcodeproj -scheme KeeLocker -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/keelocker-derived -only-testing:KeeLockerTests test
```

Use your host's command wrapper where required. Rust format/save changes also
need independent KeePassXC interoperability; UI and Touch ID changes need the
host checks described in the verification guide. Regenerate UniFFI artifacts
when changing exported APIs. Preserve the vendored patch and its regression
coverage when updating dependencies.

After dependency changes, run `cargo fetch --locked`, then
`python3 scripts/generate-notices.py` to regenerate
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The generator uses cached,
locked sources and includes binding-generation dependencies. Review the notices
alongside the manifest and lockfile changes; do not edit the inventory by hand.

Include a regression that fails before a behavioral fix where practical.
Describe commands actually run and any skipped or blocked checks. Update the
relevant topic docs when changing an invariant. Keep per-run test counts and
machine timings in the pull request, not permanent documentation.

Contributions to KeeLocker's own code are made under the [MIT license](LICENSE).
Preserve third-party license and attribution notices.
