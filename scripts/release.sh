#!/bin/bash
# Run from any directory. Produces the unsigned DMG used by GitHub Releases.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:-help}"
LABEL="${KEELOCKER_RELEASE_LABEL:-0.1.0-beta.3}"
ARCHS="${KEELOCKER_RELEASE_ARCHS:-arm64 x86_64}"
OUTPUT="${KEELOCKER_RELEASE_OUTPUT:-}"
BUILD_NUMBER="${KEELOCKER_BUILD_NUMBER:-3}"

die() { echo "release: $*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: bash scripts/release.sh preflight|build|package APP
Environment:
  KEELOCKER_RELEASE_OUTPUT    New absolute output directory (required except preflight)
  KEELOCKER_RELEASE_ARCHS     "arm64 x86_64" (default), arm64, or x86_64
  KEELOCKER_RELEASE_LABEL     0.1.0-beta.3 (default), used for archive names
  KEELOCKER_BUILD_NUMBER      3 (default), numeric CFBundleVersion
build invokes Release xcodebuild, then packages. package copies an existing Release app.
Creates a compressed DMG containing KeeLocker.app and an Applications shortcut,
plus SHA256SUMS.txt. No Developer ID certificate or notarization is required.
See docs/release.md for installation. This script never uploads or publishes.
EOF
}

case "$MODE" in
    help|-h|--help) usage; exit 0 ;;
    preflight|build|package) ;;
    *) usage; exit 1 ;;
esac
[[ "$LABEL" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || die "Invalid release label"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "Build number must be a positive integer"
VERSION="${LABEL%%-*}"
case "$ARCHS" in
    arm64|x86_64|"arm64 x86_64") ;;
    *) die 'Architectures must be arm64, x86_64, or "arm64 x86_64"' ;;
esac
[[ "$(uname -s)" == Darwin ]] || die "macOS required"
for tool in xcodebuild cargo rustc rustup codesign ditto lipo otool vtool plutil shasum file cmp git python3 hdiutil; do
    command -v "$tool" >/dev/null || die "Missing tool: $tool"
done

if [[ "$MODE" == preflight ]]; then
    sw_vers
    uname -m
    xcode-select -p
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(xcode-select -p)/../Info.plist"
    rustc --version
    cargo --version
    rustup target list --installed
    echo "Requested candidate: $LABEL ($BUILD_NUMBER), architectures: $ARCHS"
    echo "Distribution: unsigned DMG. See README.md for first-launch instructions."
    exit 0
fi

[[ "$OUTPUT" == /* ]] || die "Set KEELOCKER_RELEASE_OUTPUT to a new absolute directory"
[[ ! -e "$OUTPUT" ]] || die "Output already exists; use a fresh directory"
if [[ "$MODE" == build ]]; then
    [[ $# == 1 ]] || die "build takes no app path"
else
    [[ $# == 2 ]] || die "$MODE requires an app path"
    [[ "$2" == /* && -d "$2" && ! -L "$2" ]] || die "Supply an absolute app directory"
fi
mkdir "$OUTPUT"
sw_vers > "$OUTPUT/host.txt"
uname -m >> "$OUTPUT/host.txt"
rustc --version >> "$OUTPUT/host.txt"
cargo --version >> "$OUTPUT/host.txt"
git rev-parse HEAD > "$OUTPUT/source-revision.txt"
git status --short > "$OUTPUT/source-status.txt"
python3 scripts/generate-notices.py --check > "$OUTPUT/notices-check.txt"

if [[ "$MODE" == build ]]; then
    for arch in $ARCHS; do
        case "$arch" in
            arm64) target=aarch64-apple-darwin ;;
            x86_64) target=x86_64-apple-darwin ;;
        esac
        rustup target list --installed | grep -Fx "$target" >/dev/null || die "Install Rust target $target"
    done
    echo "Building Release; log: $OUTPUT/build.log"
    xcodebuild -project KeeLocker.xcodeproj -scheme KeeLocker -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath "$OUTPUT/DerivedData" \
        "ARCHS=$ARCHS" ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=14.0 \
        "MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" \
        CODE_SIGNING_ALLOWED=NO ENABLE_HARDENED_RUNTIME=YES build > "$OUTPUT/build.log" 2>&1
    SOURCE_APP="$OUTPUT/DerivedData/Build/Products/Release/KeeLocker.app"
else
    SOURCE_APP="$2"
fi
APP="$OUTPUT/KeeLocker.app"
ditto "$SOURCE_APP" "$APP"
PLIST="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
[[ "$(plist CFBundleExecutable)" == KeeLocker ]] || die "Unexpected executable"
[[ "$(plist CFBundleIdentifier)" == com.keelocker.desktop ]] || die "Unexpected bundle ID"
[[ "$(plist CFBundleShortVersionString)" == "$VERSION" ]] || die "App version differs from label"
[[ "$(plist CFBundleVersion)" == "$BUILD_NUMBER" ]] || die "App build number differs"
[[ "$(plist LSMinimumSystemVersion)" == 14.0 ]] || die "Unexpected minimum macOS"
plutil -p "$PLIST" > "$OUTPUT/info-plist.txt"
for notice in LICENSE THIRD_PARTY_NOTICES.md; do
    cmp "$ROOT/$notice" "$APP/Contents/Resources/$notice" || die "Missing or stale bundled $notice"
done
find "$APP" -print > "$OUTPUT/bundle-files.txt"
EXECUTABLE="$APP/Contents/MacOS/KeeLocker"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
[[ "$(plist SUPublicEDKey)" == "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT/KeeLocker/Updates/Info.plist")" ]] || die "Unexpected update public key"
[[ "$(plist SUFeedURL)" == "https://github.com/keelocker/keelocker/releases/latest/download/appcast.xml" ]] || die "Unexpected update feed"
[[ "$(plist SURequireSignedFeed)" == true && "$(plist SUVerifyUpdateBeforeExtraction)" == true ]] || die "Unsigned updates must be rejected"
bash "$ROOT/scripts/sign-sparkle.sh" "$FRAMEWORK"
SPARKLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$FRAMEWORK/Resources/Info.plist")"
python3 - "$ROOT" "$SPARKLE_VERSION" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
resolved = json.loads((root / "KeeLocker.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())
version = next(pin["state"]["version"] for pin in resolved["pins"] if pin["identity"] == "sparkle")
if version != sys.argv[2] or not (root / "licenses" / f"Sparkle-{version}.txt").is_file():
    sys.exit("Unexpected Sparkle version or missing license")
PY
# Admit only the pinned framework's reviewed binaries.
while IFS= read -r -d '' item; do
    description="$(file -b "$item")"
    if [[ "$description" == *Mach-O* && "$item" != "$EXECUTABLE" ]]; then
        case "$item" in
            "$FRAMEWORK/Versions/B/Sparkle"|"$FRAMEWORK/Versions/B/Autoupdate"|\
            "$FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater"|\
            "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"|\
            "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer")
                for arch in $ARCHS; do lipo "$item" -verify_arch "$arch"; done
                dependencies="$(otool -L "$item")"
                while IFS= read -r dependency; do
                    case "$dependency" in
                        /System/Library/*|/usr/lib/*|@rpath/Sparkle.framework/Versions/B/Sparkle) ;;
                        *) die "Unexpected Sparkle dependency: $dependency" ;;
                    esac
                done < <(awk '/^\t/ { print $1 }' <<< "$dependencies")
                ;;
            *) die "Unexpected nested Mach-O code: $item" ;;
        esac
    fi
done < <(find "$APP" -type f -print0)
lipo -archs "$EXECUTABLE" > "$OUTPUT/architectures.txt"
read -r -a actual_archs < "$OUTPUT/architectures.txt"
read -r -a expected_archs <<< "$ARCHS"
[[ ${#actual_archs[@]} == ${#expected_archs[@]} ]] || die "Unexpected architecture count"
for arch in $ARCHS; do
    lipo "$EXECUTABLE" -verify_arch "$arch"
done
vtool -show-build "$EXECUTABLE" > "$OUTPUT/mach-o-build.txt"
min_versions="$(awk '$1 == "minos" { print $2 }' "$OUTPUT/mach-o-build.txt")"
[[ -n "$min_versions" ]] || die "No Mach-O deployment target found"
while IFS= read -r min_version; do
    [[ "$min_version" == 14.0 || "$min_version" == 14.0.0 ]] || die "Mach-O requires macOS $min_version"
done <<< "$min_versions"
otool -L "$EXECUTABLE" > "$OUTPUT/libraries.txt"
while IFS= read -r dependency; do
    case "$dependency" in
        /System/Library/*|/usr/lib/*|@rpath/Sparkle.framework/Versions/B/Sparkle) ;;
        *) die "Non-system dynamic dependency needs review: $dependency" ;;
    esac
done < <(awk '/^\t/ { print $1 }' "$OUTPUT/libraries.txt")

# An ad-hoc integrity seal is needed for Apple Silicon. It does not identify a
# developer or provide notarization, and distribution requires no certificate.
codesign --force --sign - --options runtime --timestamp=none --entitlements "$ROOT/KeeLocker/KeeLocker.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2> "$OUTPUT/signature-verify.txt"
codesign --display --verbose=4 "$APP" 2> "$OUTPUT/signature.txt"
grep -Eq 'flags=.*\(.*runtime' "$OUTPUT/signature.txt" || die "Hardened runtime missing"
codesign --display --entitlements :- "$APP" > "$OUTPUT/entitlements.plist" 2> "$OUTPUT/entitlements-log.txt"
python3 - "$ROOT/KeeLocker/KeeLocker.entitlements" "$OUTPUT/entitlements.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as source, open(sys.argv[2], 'rb') as signed:
    if plistlib.load(source) != plistlib.load(signed):
        sys.exit("Unexpected distribution entitlements")
PY
ARCH_LABEL="${ARCHS// /-}"
if [[ "$ARCHS" == "arm64 x86_64" ]]; then ARCH_LABEL=universal; fi
DMG_NAME="KeeLocker-$LABEL-$ARCH_LABEL.dmg"
DMG="$OUTPUT/$DMG_NAME"
STAGING="$(mktemp -d "$OUTPUT/.dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
chmod 755 "$STAGING"
ditto "$APP" "$STAGING/KeeLocker.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "KeeLocker $LABEL" -srcfolder "$STAGING" \
    -format UDZO -fs HFS+ "$DMG" > "$OUTPUT/dmg-create.log" 2>&1
hdiutil verify "$DMG" > "$OUTPUT/dmg-verify.log" 2>&1
(
    cd "$OUTPUT"
    shasum -a 256 "$DMG_NAME" > SHA256SUMS.txt
)
printf '%s\n' "Unsigned DMG" "Candidate: $LABEL ($BUILD_NUMBER)" > "$OUTPUT/STATUS.txt"
echo "Created $DMG"
echo "Install: open the DMG and drag KeeLocker to Applications. See README.md for first launch."
