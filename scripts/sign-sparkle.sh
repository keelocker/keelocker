#!/bin/bash
# KeeLocker's non-sandboxed, ad-hoc distribution; no Apple account required.
set -euo pipefail
FRAMEWORK="${1:?Supply the embedded Sparkle.framework path}"
[[ -d "$FRAMEWORK" && ! -L "$FRAMEWORK" ]] || { echo "Missing embedded Sparkle" >&2; exit 1; }
VERSION="$FRAMEWORK/Versions/B"
for component in \
    "$VERSION/XPCServices/Downloader.xpc" \
    "$VERSION/XPCServices/Installer.xpc" \
    "$VERSION/Autoupdate" \
    "$VERSION/Updater.app" \
    "$FRAMEWORK"; do
    [[ -e "$component" ]] || { echo "Unexpected Sparkle bundle layout" >&2; exit 1; }
    codesign --force --sign - --options runtime --timestamp=none "$component"
done
codesign --verify --deep --strict "$FRAMEWORK"
