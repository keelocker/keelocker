#!/usr/bin/env python3
"""Verify the real release/feed pipeline with a disposable app and signing key."""
import argparse
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("feed", ROOT / "scripts/generate-update-feed.py")
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)


def run(app, tools):
    with tempfile.TemporaryDirectory(prefix="keelocker-update-integration-") as temporary:
        directory = Path(temporary)
        seed = directory / "test-seed"
        # This is an ephemeral test key, entirely independent of Keychain and production.
        swift = """
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
FileManager.default.createFile(atPath: CommandLine.arguments[1],
    contents: Data(key.rawRepresentation.base64EncodedString().utf8),
    attributes: [.posixPermissions: 0o600])
print(key.publicKey.rawRepresentation.base64EncodedString())
"""
        swift_file = directory / "test-key.swift"
        swift_file.write_text(swift)
        public_key = subprocess.check_output(
            ["swift", "-module-cache-path", str(directory / "modules"), str(swift_file), str(seed)],
            text=True).strip()
        release = directory / "release"
        release.mkdir()
        stage = directory / "stage"
        stage.mkdir()
        copy = stage / "KeeLocker.app"
        subprocess.run(["ditto", str(app), str(copy)], check=True)
        info_path = copy / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["SUPublicEDKey"] = public_key
        info["CFBundleIdentifier"] = "com.keelocker.update-integration"
        info_path.write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", "--options", "runtime",
                        "--timestamp=none", "--entitlements", str(ROOT / "KeeLocker/KeeLocker.entitlements"),
                        str(copy)], check=True)
        subprocess.run(["ditto", str(copy), str(release / "KeeLocker.app")], check=True)
        label = info["CFBundleShortVersionString"]
        archive = release / f"KeeLocker-{label}-universal.dmg"
        subprocess.run(["hdiutil", "create", "-srcfolder", str(stage), "-format", "UDZO",
                        "-fs", "HFS+", str(archive)], check=True)
        expected = directory / "fixture/KeeLocker/Updates"
        expected.mkdir(parents=True)
        (expected / "Info.plist").write_bytes(plistlib.dumps({"SUPublicEDKey": public_key}))
        original_root = feed.ROOT
        feed.ROOT = directory / "fixture"
        event = {"repository": {"full_name": "keelocker/keelocker"}, "release": {
            "tag_name": f"v{label}", "draft": True, "prerelease": False,
            "body": "## Synthetic update\n\nSigned release notes, tested without production credentials."}}
        original_secret = os.environ.get("SPARKLE_PRIVATE_KEY")
        try:
            os.environ["SPARKLE_PRIVATE_KEY"] = seed.read_text()
            feed.generate(release, tools, event)
            signed = (release / "appcast.xml").read_bytes()
            signature = feed.validate_feed(signed, archive, info,
                f"https://github.com/keelocker/keelocker/releases/download/v{label}/{archive.name}")
            tampered = directory / "tampered.dmg"
            shutil.copyfile(archive, tampered)
            with tampered.open("ab") as target:
                target.write(b"tampered")
            changed_feed = directory / "tampered.xml"
            changed_feed.write_bytes(signed.replace(b"Synthetic update", b"Untrusted update"))
            for arguments in [(tampered, signature), (changed_feed,)]:
                result = subprocess.run([str(tools / "sign_update"), "--ed-key-file", str(seed),
                                         "--verify", *map(str, arguments)], capture_output=True)
                if result.returncode == 0:
                    raise AssertionError("Modified signed content was accepted")
            print("PASS: generated feed, matching app key, archive and feed signatures; tampering rejected.")
        finally:
            feed.ROOT = original_root
            if original_secret is None:
                os.environ.pop("SPARKLE_PRIVATE_KEY", None)
            else:
                os.environ["SPARKLE_PRIVATE_KEY"] = original_secret


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Built universal Release app; copied, never modified")
    parser.add_argument("--tools", type=Path, required=True, help="Pinned Sparkle bin directory")
    args = parser.parse_args()
    run(args.app.resolve(), args.tools.resolve())
