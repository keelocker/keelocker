# Release preparation

The first candidate is **0.1.0-beta.1**, a limited beta. A successful build alone
does not authorize a stable release. Use the [changelog](../CHANGELOG.md) as draft
release notes and attach the verification report for the exact shipped archive.

## Version and source boundary

The Xcode app version is `0.1.0` with numeric build `2`. The prerelease label
belongs in archive names, release notes and the eventual `v0.1.0-beta.1` tag;
`CFBundleShortVersionString` remains a numeric three-component version. Increase
the build number for a replacement candidate, including a rebuild with fixes.
The internal Rust crate version is independent and need not change for packaging.
Do not tag, publish, or merge until the maintainer approves the concrete result.

Build from a reviewed revision with a clean working tree for distribution. Retain
the source revision, archive checksum, build log, Xcode/macOS/Rust versions,
signing identity and notarization submission ID with the release evidence.
The script records source status; local dirty builds are useful for verification
but require a new build from the final revision before distribution. Record
`xcodebuild -version` separately. Locked dependencies make resolution repeatable;
the script does not promise identical bytes across toolchains, timestamps or hosts.

## Preflight and local Release

Run from the repository root on macOS with the README toolchain installed. Apply
the host wrapper, such as `rtk`, to each command when required. The examples below
show the underlying commands. They do not inspect Keychain secret values.

```sh
bash scripts/release.sh preflight
```

Preflight lists installed Rust targets and valid signing identities, checks the
packaging tools, and reports the notarytool version and stapler location. Zero
valid identities permits local evaluation only. Universal compilation requires
both `aarch64-apple-darwin` and `x86_64-apple-darwin`; installing a target does not
verify its runtime. No notarization credentials are read by preflight.

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
env KEELOCKER_RELEASE_ARCHS="arm64 x86_64" KEELOCKER_RELEASE_OUTPUT=/tmp/keelocker-beta1-universal bash scripts/release.sh build
```

For an arm64-only candidate, omit `KEELOCKER_RELEASE_ARCHS`. Every invocation
requires a new absolute output directory and refuses an existing one. The build
uses Release, a generic macOS destination, explicit architectures, macOS 14.0,
locked Rust dependencies through the Xcode phase, and disabled Xcode signing.
It copies the app out of DerivedData, then explicitly signs the copy with
hardened runtime. The source app is not changed by packaging.

The script checks Info.plist identifiers/version/minimum OS, Mach-O architecture
and deployment targets, system-only dynamic dependencies, signature validity and
the runtime flag. Rust is linked statically. Unexpected nested Mach-O code,
non-system dependencies or entitlements require review and stop packaging. It
also regenerates notices in check mode and compares the bundled root `LICENSE`
and `THIRD_PARTY_NOTICES.md` with the repository. Keep the source and third-party
source/license links available alongside any binary distribution.

Without `KEELOCKER_SIGN_IDENTITY`, the archive is named
`KeeLocker-0.1.0-beta.1-arm64-x86_64-LOCAL-NON-DISTRIBUTABLE.zip`. This ad-hoc build
is for host evaluation only. It has no Developer ID, notarization or Gatekeeper
distribution approval. Do not send it to beta participants or describe it as a
signed distribution. `STATUS.txt` and `SHA256SUMS.txt` identify the artifact;
inspection reports sit beside them. A packaging failure leaves the output for
diagnosis and does not authorize using a partially produced archive.

To package an existing Release build without invoking xcodebuild:

```sh
env KEELOCKER_RELEASE_ARCHS="arm64 x86_64" KEELOCKER_RELEASE_OUTPUT=/tmp/keelocker-beta1-package bash scripts/release.sh package /absolute/path/to/Release/KeeLocker.app
```

`package` cannot prove which Xcode configuration produced its input. Supply a
Release build and retain its original build log and source revision; its reports
record the current checkout, which must match that input. Tests and debug apps
are not substitute release inputs.

## Developer ID, notarization and final archive

The maintainer supplies an installed **Developer ID Application** identity with
its private key. The script neither imports certificates nor reads key material.
Use the full identity name returned by `security find-identity -v -p codesigning`.
No hardened-runtime exceptions are currently needed; an unexpected entitlement
fails packaging. Signing is performed explicitly on the copied app without
`--deep`; no nested code exists in the expected bundle.

```sh
env KEELOCKER_SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" KEELOCKER_RELEASE_ARCHS="arm64 x86_64" KEELOCKER_RELEASE_OUTPUT=/tmp/keelocker-beta1-signed bash scripts/release.sh build
```

This makes a `SIGNED-UNNOTARIZED.zip` submission archive. It is not the final
download. The owner configures a notarytool Keychain profile through Apple's
supported flow outside recorded logs. Use the existing profile name below;
do not put Apple IDs, passwords, API private keys or GitHub tokens in scripts,
repository files, shell transcripts or release reports.

```sh
xcrun notarytool submit /tmp/keelocker-beta1-signed/KeeLocker-0.1.0-beta.1-arm64-x86_64-SIGNED-UNNOTARIZED.zip --keychain-profile keelocker-notary --wait --output-format json
```

Continue only after the service reports **Accepted**. Save the submission ID and
retrieve the diagnostic log if rejected. A completed command or an uploaded file
alone is insufficient. Staple the accepted ticket to the app, then make a fresh
archive containing that stapled app. ZIP archives themselves cannot be stapled.

```sh
xcrun stapler staple /tmp/keelocker-beta1-signed/KeeLocker.app
env KEELOCKER_RELEASE_ARCHS="arm64 x86_64" KEELOCKER_RELEASE_OUTPUT=/tmp/keelocker-beta1-final bash scripts/release.sh package-notarized /tmp/keelocker-beta1-signed/KeeLocker.app
```

`package-notarized` preserves the signature, requires Developer ID, secure
timestamp, hardened runtime, a valid stapled ticket and a successful Gatekeeper
assessment, then produces a `NOTARIZED.zip` and its SHA-256. Do not modify the app
afterward. Inspect the final archive's extracted app again on the clean test Mac.
Keep the submission log separate from public artifacts if it contains account
metadata. These operations upload only the app archive to Apple, never vaults.

Follow Apple's [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
and [Mac distribution packaging guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

## Candidate verification and clean installation

Run the required checks in [AGENTS.md](../AGENTS.md) and
[development.md](development.md), including independent KeePassXC interoperability
and the native UI/Touch ID checks. Use synthetic vaults and temporary copies.
Keep test results in the change report, distinguishing observed behavior from
coverage that remains unavailable. Repeat relevant checks after candidate fixes.

For the final downloaded ZIP, use a clean Mac or clean macOS VM with no KeeLocker
data, no checkout and no build tools required for running the app. Transfer via
a normal browser download that preserves quarantine, verify SHA-256, extract in
Finder, copy KeeLocker.app to Applications and launch through Finder. Keep
quarantine enabled and record Gatekeeper's first-launch behavior without an
override. An ad-hoc app launched on the development Mac is not this test. A new
user account on the same Mac is useful extra evidence, but not a clean-system test.

Verify the signature and Gatekeeper assessment on that extracted copy before
first launch using the tools built into macOS:

```sh
codesign --verify --deep --strict --verbose=2 /Applications/KeeLocker.app
spctl --assess --type execute --verbose=4 /Applications/KeeLocker.app
```

Also extract the same final ZIP on the inspection host and run
`xcrun stapler validate` on that extracted app. The clean Mac does not need Xcode
or command-line developer tools installed to run KeeLocker.

Open a copied synthetic password/key-file vault, edit/save, quit and reopen, then
independently reopen with KeePassXC. Exercise conflict Save Copy and Reload Latest,
read-only destination and failed writes without losing the in-memory edit, Lock,
Quit cancellation/confirmation, recycle/restore/permanent-delete confirmation,
and recovery into a new file including existing-destination refusal. Verify the
recovery sheet at the actual minimum window size, keyboard focus, Escape,
Return, password/key-file pickers, errors and successful-copy status in both
appearances. Record observed window dimensions or screenshots, not just a drag.

On a physical Touch ID/Secure Enclave Mac, a human must complete registration
after password unlock, Lock/unlock, cancellation, password fallback, Lock during
pending authentication, switching files, and Quit/relaunch requiring password.
Cover password-only and key-file vaults, then independently verify saved output.
A VM, injected biometric service or passing unit tests cannot establish this.

Use a report table for each candidate; fill results only after running the checks:

| macOS version/build | Architecture | Environment | Archive SHA-256 | Install/Gatekeeper | Vault flow | Touch ID |
| --- | --- | --- | --- | --- | --- | --- |
| 14.x, exact build | arm64 | Clean physical Mac or VM | Record | Pending | Pending | Physical Mac only |
| Current supported macOS, exact build | arm64 | Clean physical Mac or VM | Record | Pending | Pending | Physical Mac only |
| Supported macOS, exact build | x86_64 | Physical Intel Mac | Record | Pending | Pending | If available |

The advertised minimum is macOS 14. Compilation and Mach-O deployment metadata
do not prove it runs there. Universal slices do not prove Intel support. Leave
unavailable rows explicitly untested; restrict beta support claims to observed
systems. A stable release retaining these claims requires their runtime evidence.

## Independent backup and restoration drill

Local `.bak` and Application Support recovery copies share the Mac's disk. For
the drill, create a synthetic vault copy and a backup on another physical device
or independently recoverable storage, not a second directory or APFS volume on
the same disk. Record storage type and checksum without private file paths.

1. Close all vault writers. Copy the encrypted synthetic KDBX to the independent
   storage and compare SHA-256 with the source; retain credentials and any required
   key file through a separately recoverable secure method. A KDBX without its
   required key file cannot be recovered by KeeLocker.
2. Edit/save the working copy and verify local recovery versions. Disconnect the
   backup device and confirm the original backup is unchanged when reconnected.
3. Simulate loss using only the temporary working copy and isolated test account's
   local recovery copies. Keep the independent backup. Restore it to a new path
   on the test Mac, enter its own credentials and verify entries, attachments,
   history and groups with KeeLocker and KeePassXC.
4. Separately select a local pinned/versioned copy in Recovery Copies, authenticate
   and Restore Copy to a new name. Check exact encrypted bytes, refusal of an
   existing destination, and preservation of the current vault and dirty edits.
   Reopen explicitly. Record both drills in the candidate evidence.

Never rehearse disk loss by deleting user files. Keep the independent backup
until verification finishes. KeeLocker provides no automatic merge; do not edit
the same vault in two clients at once. Hash checks retain a check/rename race
with another writer. Replacements do not copy ACLs/xattrs; verify permissions and
managed-file policies. Local recovery cannot replace an independent backup.

## Limited beta and stable decision

Invite a small named group for one to two weeks after approving the signed,
notarized, clean-installed candidate. Start with synthetic vaults, then copied
vaults only after participants verify independent backup recovery. Keep a tested
KeePassXC fallback and the original encrypted vault. State supported test systems,
unverified architectures and known save/compatibility limitations in the invite.
Confirm private vulnerability reporting is enabled before inviting external
testers; follow [SECURITY.md](../SECURITY.md) and keep secrets out of reports.

Collect the app build, exact OS/architecture, reproduction steps and sanitized
logs for failed saves/unlocks, recovery, conflict handling, UI and Touch ID.
Stop expansion immediately for unexplained data changes, lost edits, failed
recovery or authentication/session defects. Fix and rebuild with a higher build
number, then repeat affected checks against the new archive. Elapsed beta time
alone does not establish readiness.

For a stable go decision require no unresolved data-loss/security blockers,
completed native recovery and real Touch ID checks, independent backup recovery,
successful signed/notarized artifact installation on the claimed OS/architecture
matrix, reconciled compatibility limitations, and a reviewed beta report.
The maintainer approves the specific archive/checksum and remaining limitations
before merging or publishing stable. Keep any missing evidence as a no-go item.
