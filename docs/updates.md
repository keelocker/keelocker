# App updates

KeeLocker uses the Sparkle version and revision pinned in the Xcode project
and workspace lockfile. `KeeLocker/Updates/AppUpdater.swift` owns one
`SPUStandardUpdaterController` for the process. It starts after application
launch, provides native release-notes/download/install windows, and exposes
status to the application menu and Settings. Automatic checks are on by
default; installation always requires user action. System profiling is off.
The updater has no vault/repository access.

Unit-test hosts skip updater startup. Existing UI-test launches pass
`--disable-updates` to avoid contacting production releases during unrelated
interaction tests. A manual update smoke test uses its own temporary bundle ID.

## Trust and distribution

The feed is a GitHub Release asset at
`https://github.com/keelocker/keelocker/releases/latest/download/appcast.xml`.
Each item points to an immutable version-tagged universal DMG in the same
repository. Both feed and archive require Ed25519 signatures. Validation occurs
before archive extraction, and signed-feed validation never expires into an
unsigned fallback. The public key lives in `KeeLocker/Updates/Info.plist`.
Private keys must never enter source, app bundles, logs or release artifacts.

This distribution uses ad-hoc signatures without Developer ID or notarization.
Hardened Runtime remains enabled in packaged releases, with the explicitly
approved `com.apple.security.cs.disable-library-validation` entitlement: ad-hoc
KeeLocker cannot share an Apple Team ID with Sparkle. This weakens macOS library
validation, independently of update signature checks. Packaging admits only
Sparkle's known binaries, signs helpers inside out and validates the exact
expected entitlement dictionary. Before switching to Developer ID, remove the
exception, use the same signing identity for all nested code, and test the
transition rather than retaining the exception by default.

## Installation and restart

Sparkle replaces the current app bundle and relaunches it. It does not install
a sibling app or modify vault files, backups or preferences. Install the first
updater-enabled build manually in Applications and eject the DMG first.
Read-only disk images/app translocation can prevent updates. macOS may request
permission to modify an app or authentication for a protected installation.

Sparkle's quit request reaches `VaultApplicationDelegate.applicationShouldTerminate`.
Every window must permit leaving before any store is locked or Quick Unlock
state cleared. Busy operations and drafts block leaving. Dirty vaults use the
existing Cancel/Discard confirmation; choose Cancel and File → Save to retain
changes. Recheck session identity and busy/draft state after native dialogs.
Cancelled termination leaves the installer waiting; the current app stays usable.
Confirmed Quit also clears the owned clipboard value according to its preference
and clears session Quick Unlock material.

## Release key setup

The production key is stored in macOS login Keychain under account
`com.keelocker.desktop.updates`. Official tools are in
`DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin` after package resolution.
`generate_keys --account com.keelocker.desktop.updates -p` prints only the public
key. Compare it to Info.plist before releasing.

For GitHub Actions, export this same key with `generate_keys --account
com.keelocker.desktop.updates -x /absolute/private/path/key`, put the file's value
in repository Actions secret `SPARKLE_PRIVATE_KEY` through a trusted secret
entry flow, then securely remove the temporary export. Never print the key in
chat or a terminal log. Keep an independently recoverable protected backup.
Losing the only key without Developer ID prevents future authenticated updates;
users then need a manually installed build with a new public key.

The release workflow requires this secret before building, then invokes
`scripts/publish-update.py` for an existing release draft.
`scripts/generate-update-feed.py` calls official pinned
`generate_appcast` and `sign_update`, embeds GitHub release notes, validates
tag/build/URL/archive length/signature and verifies both signatures. Secret
material travels through stdin and is removed from child process environments.
Local generation can use the Keychain account instead.
Release notes normalize CRLF/CR line endings to LF before embedding and comparing
with XML. Other content and Markdown whitespace must still match; resumed feeds
use the same comparison.

Create a reviewed tag and a release draft with nonempty notes and an increased
numeric `CFBundleVersion`. Keep the release as a draft. In Actions, run
**Release DMG** from the reviewed workflow revision and enter the tag. The workflow
builds that exact tag, signs and verifies its assets, downloads each uploaded
asset for comparison, then publishes the draft. A stable release becomes latest
only after all three assets are ready; a beta remains a prerelease. A beta tag
must have the prerelease checkbox enabled, and a stable tag must not.

No extra hosting service is needed. The `latest` endpoint follows GitHub's
latest stable release; beta releases do not replace that feed. Before the first
stable updater-enabled release, manual production checks may report an unavailable
feed. Build numbers must increase across releases, including betas; changing only
the marketing version does not trigger an update. The publisher compares the
candidate build against the previous stable signed feed when one exists.

If an upload fails, rerun the workflow with the same draft/tag. Existing assets
are never overwritten: it downloads the exact uploaded DMG, checks its embedded
app/version/signatures, and generates the missing feed for those bytes. Existing
checksums and feeds are verified before reuse. Unexpected/incomplete asset records,
changed notes, another build number or a signature mismatch stop publication for
maintainer inspection. Do not manually publish a partially prepared draft.

## Verification and rollback

Run Swift `AppUpdateTests` and clipboard tests, `python3
scripts/test-update-feed.py`, `python3 scripts/test-release-publication.py`,
the notices check and Release packaging. Verify
packaged entitlements, nested signatures and dependency inventory. Sparkle's
tools must reject a changed archive and a changed signed feed.

With a built universal Release app and the pinned Sparkle tools, run:

```sh
python3 scripts/test-update-feed-integration.py --app /absolute/path/to/KeeLocker.app --tools /absolute/path/to/Sparkle/bin
```

This copies the app to a temporary directory and generates an ephemeral test key
and DMG. It exercises feed creation and modified-content rejection without reading
or exporting the production Keychain key. It never modifies the supplied app.

Use a temporary app installation and synthetic demo/vault with two increasing
build numbers: check window/notes, Later/Skip, download cancellation, installation
and relaunch at the same path. Check no-update and offline errors, dirty edits,
drafts, busy operations and cancelled Quit. Inspect Settings and update windows
in both appearances, including keyboard focus. Test Gatekeeper and App Management
on a clean Mac separately; a build-machine check is narrower evidence.
For an isolated test feed, modify and re-sign only temporary app copies; never
weaken production HTTPS or signature settings.

An interrupted draft does not replace the previous latest release. Inspect a
failed publication readback before retrying; an already published release is
rejected rather than silently modified. To withdraw a bad published version,
move latest back to the previous compatible release; installed newer builds will not downgrade.
Repair with a higher build number. Code rollback needs no vault migration.
Do not overwrite existing release assets or regenerate production keys as a retry.
