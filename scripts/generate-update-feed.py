#!/usr/bin/env python3
"""Generate and verify a signed Sparkle feed for a packaged GitHub release.

Uses the official, SPM-pinned Sparkle tools. The private key is supplied through
stdin from SPARKLE_PRIVATE_KEY in CI, or read from KeeLocker's Keychain account.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "keelocker/keelocker"
NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ACCOUNT = "com.keelocker.desktop.updates"


def run_tool(tools, tool, *args):
    secret = os.environ.get("SPARKLE_PRIVATE_KEY")
    credentials = ["--ed-key-file", "-"] if secret else ["--account", ACCOUNT]
    child_env = {key: value for key, value in os.environ.items() if key != "SPARKLE_PRIVATE_KEY"}
    subprocess.run([str(tools / tool), *credentials, *map(str, args)],
                   input=secret.encode() if secret else None, env=child_env, check=True)


def verify(tools, file, signature=None):
    run_tool(tools, "sign_update", "--verify", file, *([signature] if signature else []))


def validate_feed(feed, archive, info, download_url, expected_notes=None):
    items = ET.fromstring(feed).findall("./channel/item")
    if len(items) != 1:
        raise ValueError("Expected exactly one update")
    item = items[0]
    if item.findtext(f"{{{NAMESPACE}}}version") != str(info["CFBundleVersion"]):
        raise ValueError("Feed build number does not match packaged app")
    if item.findtext(f"{{{NAMESPACE}}}minimumSystemVersion") not in ("14.0", "14.0.0"):
        raise ValueError("Unexpected minimum macOS")
    enclosure = item.find("enclosure")
    if enclosure is None or enclosure.get("url") != download_url:
        raise ValueError("Unexpected download URL")
    if enclosure.get("length") != str(archive.stat().st_size):
        raise ValueError("Archive length does not match")
    signature = enclosure.get(f"{{{NAMESPACE}}}edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Missing Ed25519 signature; check signing key matches app")
    notes = item.findtext("description")
    if not notes:
        raise ValueError("Missing release notes")
    if expected_notes is not None and notes.strip() != expected_notes.strip():
        raise ValueError("Release notes differ from the signed feed; use a new draft/tag")
    return signature


def validate_release(info, release, repository):
    tag = release["tag_name"]
    if not re.fullmatch(r"v?[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", tag):
        raise ValueError("Invalid release tag")
    if repository != REPOSITORY:
        raise ValueError("Refusing to publish updates for another repository")
    if not release.get("draft"):
        raise ValueError("Prepare updates in a draft; publish only after asset verification")
    label = tag.removeprefix("v")
    if bool(release.get("prerelease")) != ("-" in label):
        raise ValueError("Release tag and prerelease setting differ")
    if info["CFBundleShortVersionString"] != label.split("-")[0]:
        raise ValueError("Release tag and app version differ")
    if not re.fullmatch(r"[1-9][0-9]*", str(info["CFBundleVersion"])):
        raise ValueError("Build number must be a positive integer")
    if not (release.get("body") or "").strip():
        raise ValueError("Add release notes before publishing")
    return label


def generate(release_dir, tools, event):
    archives = list(release_dir.glob("KeeLocker-*.dmg"))
    if len(archives) != 1:
        raise ValueError("Expected one packaged DMG")
    archive = archives[0]
    info = plistlib.loads((release_dir / "KeeLocker.app/Contents/Info.plist").read_bytes())
    expected = plistlib.loads((ROOT / "KeeLocker/Updates/Info.plist").read_bytes())
    if info.get("SUPublicEDKey") != expected["SUPublicEDKey"]:
        raise ValueError("Packaged update key differs from the checked-in public key")
    if not info.get("SURequireSignedFeed") or not info.get("SUVerifyUpdateBeforeExtraction"):
        raise ValueError("Packaged app must require signed feeds and archives")
    release = event["release"]
    tag = release["tag_name"]
    label = validate_release(info, release, event["repository"]["full_name"])
    if archive.name != f"KeeLocker-{label}-universal.dmg":
        raise ValueError("Only the universal DMG can be published as an update")
    notes = (release.get("body") or "").strip()
    if not notes:
        raise ValueError("Add release notes before publishing")
    prefix = f"https://github.com/{REPOSITORY}/releases/download/{tag}/"
    # Use a fresh directory so stale unsigned feeds or archives cannot enter the release.
    with tempfile.TemporaryDirectory(prefix="keelocker-feed-") as temporary:
        stage = Path(temporary)
        staged_archive = stage / archive.name
        shutil.copyfile(archive, staged_archive)
        (stage / (archive.stem + ".md")).write_text(notes + "\n", encoding="utf-8")
        feed = stage / "appcast.xml"
        run_tool(tools, "generate_appcast", "--maximum-deltas", "0", "--maximum-versions", "1",
            "--embed-release-notes", "--download-url-prefix", prefix,
            "--link", f"https://github.com/{REPOSITORY}/releases/tag/{tag}",
            "-o", feed, stage)
        signature = validate_feed(feed.read_bytes(), archive, info, prefix + archive.name, notes)
        verify(tools, archive, signature)
        verify(tools, feed)
        destination = release_dir / "appcast.xml"
        if destination.exists():
            raise ValueError("Feed already exists; use a fresh release directory")
        shutil.copyfile(feed, destination)
    print("Signed archive and feed verified. Ready to upload appcast.xml.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-dir", type=Path, required=True)
    parser.add_argument("--tools", type=Path, required=True)
    parser.add_argument("--event", type=Path, required=True)
    arguments = parser.parse_args()
    generate(arguments.release_dir.resolve(), arguments.tools.resolve(),
             json.loads(arguments.event.read_text(encoding="utf-8")))
