# Changelog

## 0.1.0-beta.1, build 2 (unreleased candidate)

First limited beta of KeeLocker for macOS, pending release verification and
maintainer approval. Use copied vaults and keep a verified independent backup.

- Open existing KDBX 3.1, 4.0 and 4.1 vaults with a password and optional key file, and save edits as KDBX 4.1 while retaining cipher and KDF settings.
- Edit entries, groups, tags, protected custom fields, attachments and icons in a native macOS interface, with entry history and TOTP display.
- Save existing-item changes automatically, keep new entries as drafts until Save, and retain unsaved edits when persistence fails.
- Keep encrypted original and versioned recovery copies, restore a selected copy into a new file, and recover conflicts through Save Copy or explicit reload.
- Move deleted entries to the imported vault's enabled Recycle Bin, restore their location, and require confirmation for permanent deletion.
- Prepare session-only Touch ID after password unlock on supported Macs, with password access after cancellation and a fresh password unlock after Quit.
- Download website icons manually or through an optional setting that is off by default.

macOS 14 is the build minimum; runtime support must be confirmed for each system
and architecture listed with the released artifact. Intel runtime and real
biometric behavior require separate verification. An ad-hoc local build is
non-distributable. See the [release procedure](docs/release.md) for candidate gates.

Saving upgrades older supported vaults to KDBX 4.1. Unsupported extensions or
costs are rejected; settings are not lowered. Automatic merge, database creation,
master-key changes, persistent Keychain unlock and hardware keys are unavailable.
Another writer can still race a save, and replacement does not preserve ACLs or
extended attributes. Recovery copies on the same disk cannot protect against
loss of that disk. See [safe-save limitations](README.md#safe-save-and-limitations).
