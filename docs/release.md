# Releases

KeeLocker ships as a universal DMG without Developer ID signing or notarization.
Install by dragging the app to Applications, then use **Open Anyway** in System
Settings if macOS blocks the first launch. See the [installation instructions](../README.md#install).
This distribution method does not require an Apple Developer account.

## Version and build

The in-app update verification candidate is `0.1.0-beta.5`, build `5`. The Xcode app version remains
numeric (`0.1.0`); the beta label belongs in the tag and DMG name. Increase the
build number when replacing a candidate with fixes. The Rust crate version is
independent of the app version.

Build from the reviewed revision with a clean working tree. Retain the revision,
DMG checksum, build log and macOS/Xcode/Rust versions with the verification
report. Locked dependencies do not guarantee identical bytes across toolchains
and hosts. Test results belong in the report, with only the tested system matrix
and user-facing limitations in release notes.

## Build a DMG

Run from the repository root on macOS with the [build toolchain](../README.md#build)
installed. Apply the host wrapper, such as RTK, when required.

```sh
bash scripts/release.sh preflight
rustup target add aarch64-apple-darwin x86_64-apple-darwin
env KEELOCKER_RELEASE_OUTPUT=/tmp/keelocker-beta5-dmg bash scripts/release.sh build
```

The default is universal (`arm64 x86_64`). Set `KEELOCKER_RELEASE_ARCHS=arm64`
or `x86_64` for a single architecture. Every run requires a new absolute output
directory. Set `KEELOCKER_RELEASE_LABEL` and `KEELOCKER_BUILD_NUMBER` to match
the candidate when they differ from the script defaults.

The script builds Release, packages `KeeLocker.app` with an Applications link,
and creates `KeeLocker-0.1.0-beta.5-universal.dmg` and `SHA256SUMS.txt`. It checks
the app version, architectures, deployment target, system library dependencies
and bundled licenses. Rust is statically linked. A local integrity signature
and hardened runtime are applied during packaging; neither is an Apple Developer
ID signature or notarization. Sparkle's nested helpers are signed inside out.
The approved library-validation exception permits Sparkle to load in the ad-hoc
app while keeping Hardened Runtime enabled. Build and inspection reports stay
beside the DMG; see [update trust and key setup](updates.md).

To package an existing Release app:

```sh
env KEELOCKER_RELEASE_OUTPUT=/tmp/keelocker-beta5-package bash scripts/release.sh package /absolute/path/to/Release/KeeLocker.app
```

Keep its original build log and source revision. Packaging cannot establish
which build configuration produced an arbitrary app. Do not use partial output
from a failed build.

## GitHub release assets

After approval, a maintainer creates a tag and a **draft** release for the reviewed
revision, such as `0.1.0-beta.5`, using the [changelog](../CHANGELOG.md) for notes.
Keep the release unpublished. Run **Actions → Release DMG → Run workflow** from
the reviewed workflow revision and supply that tag. The workflow checks out the
tag, uses publishing scripts from the selected workflow revision, uses the same
pinned Xcode as CI and builds the universal DMG. Packaging sets the initial
channel to Beta for prerelease tags and Stable for stable tags.
It uploads the `.dmg`, `SHA256SUMS.txt` and signed `appcast.xml`, then downloads
and verifies every asset before publishing the draft. Only a completed stable
release becomes latest; beta tags require a prerelease draft. The previous update
feed stays available during preparation and failed uploads. After publication,
the workflow commits the merged signed Stable/Beta feed to the `updates` branch
and verifies its bytes. This branch is created on first publication and needs
no separate hosting setup. If that final step fails, rerun with **Only retry
channel feed publication** enabled for the same published tag. See [updates](updates.md).
The feed uses version-tagged URLs and embeds the draft's notes. No Apple
signing certificate is needed. Configure the existing production key as Actions
secret `SPARKLE_PRIVATE_KEY` first, following [updates](updates.md).

The workflow obtains the release label from the tag and the numeric build
number from the Xcode project. It uses the workflow's repository token for the
asset upload and final publication. It does not create release drafts or replace
assets. A rerun resumes from the uploaded DMG instead of substituting a rebuilt
archive; checksum/feed mismatches or changed notes require inspection. Starting
this workflow authorizes publication of that specific draft. Merely creating a
draft, commit or pull request does not publish anything.

## Verify the downloadable artifact

Run the checks in [AGENTS.md](../AGENTS.md) and [development.md](development.md),
including independent KeePassXC interoperability and native UI checks. Use
synthetic vaults and temporary copies. Repeat affected checks after fixes.

Download the final DMG through a browser on a clean Mac or clean macOS VM without
a checkout or build tools. Compare its SHA-256 with `SHA256SUMS.txt`, mount it,
drag KeeLocker to Applications, eject it and launch from Applications. Follow
the documented **Open Anyway** flow without disabling Gatekeeper. Record the
exact OS build, architecture and DMG checksum. A launch on the build machine
or a fresh user account is useful evidence but does not cover a clean system.

Exercise password/key-file unlock, edit/save, Quit/reopen and independent
KeePassXC reopen. Check conflict Save Copy/Reload Latest, failed writes, Lock,
Quit cancellation, recycle/restore and recovery to a new file. Inspect the
recovery sheet at the actual minimum window size in both appearances, including
keyboard focus, Escape/Return, pickers and errors.

On a physical Touch ID Mac, check enrollment, Lock/unlock, cancellation,
password fallback, late authentication results and password unlock after
Quit/relaunch. Include key-file vaults. Unit tests and VMs do not establish
real biometric behavior.

Record each tested macOS version/build and architecture separately. The build
minimum is macOS 14; compilation does not verify runtime compatibility there.
Universal code also does not establish Intel runtime coverage. Mark unavailable
environments untested and limit support claims accordingly. Missing Developer
ID signing or notarization is not a release blocker for this distribution.

## Independent backup and recovery

Local `.bak` and Application Support recovery copies share the Mac's disk.
Verify independent recovery with a synthetic vault on another physical device
or independently recoverable storage. A second directory or APFS volume on the
same disk does not cover disk loss.

1. Close vault writers. Copy the encrypted synthetic KDBX to the independent
   storage and compare checksums. Keep its credentials and required key file
   recoverable separately.
2. Edit/save the working copy, disconnect the backup storage and verify that the
   backup remains unchanged when reconnected.
3. Remove only the temporary working copy and isolated test account's local
   recovery copies. Restore the independent backup to a new path, unlock it
   and verify entries, history, groups and attachments in KeeLocker and KeePassXC.
4. Separately use **Recovery Copies** to restore a local version to a new file.
   Verify exact encrypted bytes, existing-destination refusal and retention of
   the current vault and dirty edits. Open the restored copy explicitly.

Keep the independent backup through verification. Do not edit the same vault
concurrently in multiple clients: there is no automatic merge and a check/rename
race remains. Replacements do not copy ACLs or extended attributes. Verify
permissions for shared or managed files. See [save limitations](../README.md#safe-save-and-limitations).

## Limited beta

Start with a small group for one to two weeks using synthetic vaults, then copies
with an independent backup and a KeePassXC fallback. Collect the app build,
OS/architecture and reproduction steps. Stop expansion for unexplained data
changes, lost edits, failed recovery or authentication defects; fix, rebuild
and repeat the affected checks.

Decide stable readiness from the tested artifact, native checks, independent
recovery, actual OS/architecture coverage and beta results. Record unresolved
defects and coverage gaps explicitly. The maintainer approves the specific
artifact and remaining limitations before stable publication.
