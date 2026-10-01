#!/bin/bash
set -euo pipefail
export PATH="${HOME}/.cargo/bin:${PATH}"
cd "${SRCROOT}"
libraries=()
for architecture in ${ARCHS}; do
    case "$architecture" in
        arm64) rust_target=aarch64-apple-darwin ;;
        x86_64) rust_target=x86_64-apple-darwin ;;
        *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;;
    esac
    cargo build --locked --release --lib -p keelocker-core --target "$rust_target"
    libraries+=("${SRCROOT}/target/${rust_target}/release/libkeelocker_core.a")
done
mkdir -p "${BUILT_PRODUCTS_DIR}"
lipo -create "${libraries[@]}" -output "${BUILT_PRODUCTS_DIR}/libkeelocker_core.a"
