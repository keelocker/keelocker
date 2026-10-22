#!/bin/bash
# Run from any directory. Never uploads, reads signing secrets, or publishes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:-help}"
LABEL="${KEELOCKER_RELEASE_LABEL:-0.1.0-beta.1}"
ARCHS="${KEELOCKER_RELEASE_ARCHS:-arm64}"
IDENTITY="${KEELOCKER_SIGN_IDENTITY:-}"
OUTPUT="${KEELOCKER_RELEASE_OUTPUT:-}"
BUILD_NUMBER="${KEELOCKER_BUILD_NUMBER:-2}"

die() { echo "release: $*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: bash scripts/release.sh preflight|build|package APP|package-notarized APP
Environment:
  KEELOCKER_RELEASE_OUTPUT    New absolute output directory (required except preflight)
  KEELOCKER_RELEASE_ARCHS     arm64 (default), x86_64, or "arm64 x86_64"
  KEELOCKER_RELEASE_LABEL     0.1.0-beta.1 (default), used for archive names
  KEELOCKER_BUILD_NUMBER      2 (default), numeric CFBundleVersion
  KEELOCKER_SIGN_IDENTITY     Full "Developer ID Application: ..." name (optional)
build invokes Release xcodebuild, then packages. package copies an existing Release app.
Without an identity these modes create LOCAL-NON-DISTRIBUTABLE ad-hoc artifacts.
With an identity they create SIGNED-UNNOTARIZED artifacts for notarytool submission.
package-notarized copies an already stapled app, verifies it, and makes the final ZIP.
See docs/release.md. No automatic notarization or publication occurs.
EOF
}

case "$MODE" in
    help|-h|--help) usage; exit 0 ;;
    preflight|build|package|package-notarized) ;;
    *) usage; exit 1 ;;
esac
[[ "$LABEL" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || die "Invalid release label"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "Build number must be a positive integer"
VERSION="${LABEL%%-*}"
case "$ARCHS" in
    arm64|x86_64|"arm64 x86_64") ;;
    *) die 'Architectures must be arm64, x86_64, or "arm64 x86_64"' ;;
esac
if [[ -n "$IDENTITY" && "$IDENTITY" != "Developer ID Application: "* ]]; then
    die "Supply a Developer ID Application identity, or leave it unset for local use"
fi
[[ "$(uname -s)" == Darwin ]] || die "macOS required"
for tool in xcodebuild xcrun cargo rustc rustup codesign security ditto lipo otool vtool plutil shasum file cmp git python3 spctl; do
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
    security find-identity -v -p codesigning
    xcrun notarytool --version
    xcrun --find stapler
    echo "Requested candidate: $LABEL ($BUILD_NUMBER), architectures: $ARCHS"
    echo "Preflight does not prove build, signing, notarization, or runtime coverage."
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
# Rust is statically linked. Fail closed if packaging gains nested code: each such
# component needs its own dependency, license, deployment, and inside-out signing review.
while IFS= read -r -d '' item; do
    description="$(file -b "$item")"
    if [[ "$description" == *Mach-O* && "$item" != "$EXECUTABLE" ]]; then
        die "Unexpected nested Mach-O code: $item"
    fi
done < <(find "$APP" -type f -print0)
lipo -archs "$EXECUTABLE" > "$OUTPUT/architectures.txt"
read -r -a actual_archs < "$OUTPUT/architectures.txt"
read -r -a expected_archs <<< "$ARCHS"
[[ ${#actual_archs[@]} == ${#expected_archs[@]} ]] || die "Unexpected architecture count"
for arch in $ARCHS; do
    lipo -verify_arch "$arch" "$EXECUTABLE"
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
        /System/Library/*|/usr/lib/*) ;;
        *) die "Non-system dynamic dependency needs review: $dependency" ;;
    esac
done < <(awk '/^\t/ { print $1 }' "$OUTPUT/libraries.txt")

if [[ "$MODE" == package-notarized ]]; then
    CLASS=NOTARIZED
elif [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
    CLASS=SIGNED-UNNOTARIZED
else
    codesign --force --sign - --options runtime --timestamp=none "$APP"
    CLASS=LOCAL-NON-DISTRIBUTABLE
fi
codesign --verify --deep --strict --verbose=2 "$APP" 2> "$OUTPUT/signature-verify.txt"
codesign --display --verbose=4 "$APP" 2> "$OUTPUT/signature.txt"
grep -Eq 'flags=.*\(.*runtime' "$OUTPUT/signature.txt" || die "Hardened runtime missing"
codesign --display --entitlements :- "$APP" > "$OUTPUT/entitlements.plist" 2> "$OUTPUT/entitlements-log.txt"
if [[ -s "$OUTPUT/entitlements.plist" ]]; then
    # This app needs no distribution entitlements or hardened-runtime exceptions.
    entitlements="$(plutil -convert xml1 -o - "$OUTPUT/entitlements.plist")"
    [[ "$entitlements" != *'<key>'* ]] || die "Unexpected entitlements require review"
fi
if [[ "$CLASS" != LOCAL-NON-DISTRIBUTABLE ]]; then
    grep -F 'Authority=Developer ID Application:' "$OUTPUT/signature.txt" >/dev/null || die "Developer ID signature required"
    grep -E '^Timestamp=' "$OUTPUT/signature.txt" >/dev/null || die "Secure timestamp missing"
fi
if [[ "$CLASS" == NOTARIZED ]]; then
    xcrun stapler validate "$APP" > "$OUTPUT/stapler.txt" 2>&1
    spctl --assess --type execute --verbose=4 "$APP" > "$OUTPUT/gatekeeper.txt" 2>&1
fi
ARCH_LABEL="${ARCHS// /-}"
ZIP="$OUTPUT/KeeLocker-$LABEL-$ARCH_LABEL-$CLASS.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" > "$OUTPUT/SHA256SUMS.txt"
printf '%s\n' "$CLASS" "Candidate: $LABEL ($BUILD_NUMBER)" > "$OUTPUT/STATUS.txt"
echo "Created $ZIP"
echo "Classification: $CLASS. Runtime testing and release approval remain separate."
