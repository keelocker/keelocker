#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cargo build --locked -p keelocker-core --features bindings
target/debug/uniffi-bindgen generate --library target/debug/libkeelocker_core.dylib --language swift --out-dir KeeLocker/Data/Rust/Generated
mv KeeLocker/Data/Rust/Generated/keelocker_coreFFI.modulemap KeeLocker/Data/Rust/Generated/module.modulemap
