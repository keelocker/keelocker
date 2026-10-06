# License text provenance

Cargo archives normally include their own license texts. These fallbacks cover
archives that omit them; `scripts/generate-notices.py` fails if any other missing
text appears after a dependency update.

- `MPL-2.0.txt`: [Mozilla's official MPL 2.0 text](https://www.mozilla.org/media/MPL/2.0/index.txt), for the UniFFI crates.
- `blake2b_simd-1.0.5.txt`: [upstream MIT license at the crate's recorded source commit](https://github.com/oconnor663/blake2_simd/blob/47714dc3c424e82213d7f2eb4a833e3843017be5/LICENSE).
- `block-modes-0.9.1.txt`: [official Apache 2.0 text](https://www.apache.org/licenses/LICENSE-2.0.txt). The deprecated stub crate declares `MIT OR Apache-2.0`; this distribution uses the Apache alternative. The archive has no license file or NOTICE.

The r-efi archive keeps its license and copyright statements in `AUTHORS`, which
the generator also includes. All other notices come from the exact locked crate
archives or the vendored keepass source.
