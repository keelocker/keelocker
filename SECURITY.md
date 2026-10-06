# Security policy

KeeLocker is in early development. Security fixes target the current development
branch; there are no supported stable releases or promised response deadlines.
Use synthetic vaults for evaluation and keep independent backups.

## Reporting a vulnerability

GitHub private vulnerability reporting is the selected reporting channel.
**Activation is pending verification:** maintainers must confirm that private
reporting is enabled for the repository.

Once maintainers confirm activation, report through
[GitHub's private advisory form](https://github.com/keelocker/keelocker/security/advisories/new).
Until then, do not put vulnerability details in a public issue. A public issue
may ask maintainers to activate private reporting without disclosing the finding.

Include the affected revision, impact, reproduction steps and a minimal
synthetic fixture or proof of concept. Remove passwords, key files and personal
data from real vaults. Coordinate disclosure with maintainers through the
private advisory before publishing exploit details.

## Security boundaries

KDBX parsing, encryption and KDFs use the vendored library. Safe saves validate a
round trip, retain encrypted backups and detect external changes; they cannot
provide a transaction shared with other clients. See
[safe-save limitations](README.md#safe-save-and-limitations).

Lock releases decrypted application state and the persistent Rust session.
Touch ID retains only encrypted session key material in RAM, protected by a
biometric Secure Enclave operation; Quit clears that cache. There is no guarantee
of zeroing every Swift string or copied buffer, and an unlocked process holds
plaintext. The [Touch ID document](docs/touch-id.md) describes this boundary.
