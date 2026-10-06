#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Generate into a private temporary directory without changing tracked artifacts.
generated_dir=$(mktemp -d "${TMPDIR:-/tmp}/keelocker-bindings.XXXXXX")
trap 'rm -rf "$generated_dir"' EXIT
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$PWD/target}"

case "$(uname -s)" in
    Darwin) library_name=libkeelocker_core.dylib ;;
    Linux) library_name=libkeelocker_core.so ;;
    *) echo "Binding verification supports macOS and Linux hosts." >&2; exit 1 ;;
esac

cargo build --locked -p keelocker-core --features bindings
"$CARGO_TARGET_DIR/debug/uniffi-bindgen" generate \
    --library "$CARGO_TARGET_DIR/debug/$library_name" \
    --language swift --out-dir "$generated_dir"
mv "$generated_dir/keelocker_coreFFI.modulemap" "$generated_dir/module.modulemap"
diff -ru KeeLocker/Data/Rust/Generated "$generated_dir"
