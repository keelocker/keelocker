#!/usr/bin/env python3
"""Verify and publish an existing GitHub draft; safely resume partial uploads."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("update_feed", ROOT / "scripts/generate-update-feed.py")
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)
spec = importlib.util.spec_from_file_location("update_channels", ROOT / "scripts/update-channels.py")
channels = importlib.util.module_from_spec(spec)
spec.loader.exec_module(channels)


def gh_json(*arguments, missing_ok=False, payload=None, method=None):
    command = ["gh", *arguments]
    if method:
        command.extend(["--method", method])
    if payload is not None:
        command.extend(["--input", "-"])
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            capture_output=True, text=True)
    if result.returncode:
        if missing_ok and "HTTP 404" in result.stderr:
            return None
        raise RuntimeError(f"GitHub command failed ({result.returncode}): {result.stderr.strip()}")
    return json.loads(result.stdout)


def asset_names(release):
    names = [asset["name"] for asset in release["assets"]]
    if len(set(names)) != len(names) or any(asset["state"] != "uploaded" for asset in release["assets"]):
        raise ValueError("Duplicate or incomplete release assets; inspect the draft before retrying")
    return set(names)


def release_endpoint(repository, tag):
    # gh handles the separate draft lookup; the REST tag endpoint excludes drafts.
    release = gh_json("release", "view", tag, "--repo", repository, "--json", "databaseId")
    identifier = release["databaseId"]
    if type(identifier) is not int or identifier <= 0:
        raise ValueError("Invalid release database ID")
    return f"repos/{repository}/releases/{identifier}"


def checksum(archive):
    digest = hashlib.sha256()
    with archive.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return f"{digest.hexdigest()}  {archive.name}\n"


def require_same_draft(initial, current):
    for key in ("id", "tag_name", "body", "prerelease", "target_commitish"):
        if current[key] != initial[key]:
            raise ValueError("Release metadata changed while preparing assets; inspect and rerun")
    if not current["draft"]:
        raise ValueError("Release was published before verification completed")


def publish(release_dir, tools, tag):
    repository = feed.REPOSITORY
    endpoint = release_endpoint(repository, tag)
    initial = gh_json("api", endpoint)
    built_info = plistlib.loads((release_dir / "KeeLocker.app/Contents/Info.plist").read_bytes())
    label = feed.validate_release(built_info, initial, repository)
    archive_name = f"KeeLocker-{label}-universal.dmg"
    allowed = {archive_name, "SHA256SUMS.txt", "appcast.xml"}
    existing = asset_names(initial)
    if existing - allowed:
        raise ValueError("Unexpected draft assets; use a dedicated KeeLocker release draft")

    with tempfile.TemporaryDirectory(prefix="keelocker-publication-") as temporary:
        directory = Path(temporary)
        verified = directory / "verified"
        verified.mkdir()
        archive = verified / archive_name

        def download(name, destination):
            subprocess.run(["gh", "release", "download", tag, "--repo", repository,
                            "--pattern", name, "--dir", str(destination)], check=True)

        def upload(file):
            current = gh_json("api", endpoint)
            require_same_draft(initial, current)
            if file.name in asset_names(current):
                raise ValueError("Asset appeared during publication; rerun to verify it")
            subprocess.run(["gh", "release", "upload", tag, str(file),
                            "--repo", repository], check=True)

        # Never replace an uploaded DMG with a nondeterministic rebuild.
        if archive_name in existing:
            download(archive_name, verified)
        else:
            shutil.copyfile(release_dir / archive_name, archive)

        # Read the app actually contained in the selected archive, including on retry.
        mount = directory / "mounted"
        mount.mkdir()
        subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint",
                        str(mount), str(archive)], check=True, stdout=subprocess.DEVNULL)
        try:
            app = mount / "KeeLocker.app"
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            feed.validate_release(info, initial, repository)
            if info.get("CFBundleIdentifier") != "com.keelocker.desktop":
                raise ValueError("Unexpected app bundle identity")
            if info["CFBundleVersion"] != built_info["CFBundleVersion"]:
                raise ValueError("Existing archive has another build number; use a new tag")
            subprocess.run(["lipo", str(app / "Contents/MacOS/KeeLocker"),
                            "-verify_arch", "arm64", "x86_64"], check=True)
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
            subprocess.run(["ditto", str(app), str(verified / "KeeLocker.app")], check=True)
        finally:
            subprocess.run(["hdiutil", "detach", str(mount)], check=True, stdout=subprocess.DEVNULL)

        sums = verified / "SHA256SUMS.txt"
        expected_sum = checksum(archive)
        if sums.name in existing:
            download(sums.name, verified)
            if sums.read_text() != expected_sum:
                raise ValueError("Uploaded checksum does not match the uploaded DMG")
        else:
            sums.write_text(expected_sum)

        event = {"repository": {"full_name": repository}, "release": initial}
        # Also proves the supplied signing key matches the app inside this exact DMG.
        feed.generate(verified, tools, event)
        generated_feed = verified / "appcast.xml"
        if "appcast.xml" in existing:
            old = directory / "existing-feed"
            old.mkdir()
            download("appcast.xml", old)
            feed.verify(tools, old / "appcast.xml")
            signature = feed.validate_feed((old / "appcast.xml").read_bytes(), archive, info,
                f"https://github.com/{repository}/releases/download/{tag}/{archive_name}", initial["body"],
                "beta" if initial["prerelease"] else "stable")
            feed.verify(tools, archive, signature)
            shutil.copyfile(old / "appcast.xml", generated_feed)

        prepared_channels = channels.prepare(directory, tools, generated_feed, gh_json, feed)

        # Read back each asset. A successful upload alone is not verification.
        for file in (archive, sums, generated_feed):
            if file.name not in existing:
                upload(file)
            readback = directory / ("readback-" + file.name)
            readback.mkdir()
            download(file.name, readback)
            if checksum(file) != checksum(readback / file.name):
                raise ValueError("Downloaded release asset differs from verified content")
        current = gh_json("api", endpoint)
        require_same_draft(initial, current)
        if asset_names(current) != allowed:
            raise ValueError("Release assets changed before publication")
        subprocess.run(["gh", "release", "edit", tag, "--repo", repository, "--draft=false",
                        "--latest=false" if initial["prerelease"] else "--latest"], check=True)
        published = gh_json("api", endpoint)
        if published["draft"] or asset_names(published) != allowed:
            raise ValueError("Publication readback failed")
        channels.publish(prepared_channels, gh_json)
    print(f"Published verified {'prerelease' if initial['prerelease'] else 'stable release'} {tag}.")


def refresh_channels(tools, tag):
    """Resume channel publication after a release succeeded but feed publication failed."""
    release = gh_json("api", release_endpoint(feed.REPOSITORY, tag))
    if release["draft"] or "appcast.xml" not in asset_names(release):
        raise ValueError("Channel refresh requires a published release with a signed appcast")
    with tempfile.TemporaryDirectory(prefix="keelocker-channel-refresh-") as temporary:
        directory = Path(temporary)
        subprocess.run(["gh", "release", "download", tag, "--repo", feed.REPOSITORY,
                        "--pattern", "appcast.xml", "--dir", str(directory)], check=True)
        candidate = directory / "appcast.xml"
        feed.verify(tools, candidate)
        entries = channels.items(candidate.read_bytes())
        lane = "beta" if release["prerelease"] else "stable"
        if len(entries) != 1 or lane not in entries:
            raise ValueError("Published release channel differs from its signed appcast")
        url = entries[lane].find("enclosure").get("url")
        if f"/releases/download/{tag}/" not in url:
            raise ValueError("Published appcast belongs to another tag")
        channels.publish(channels.prepare(directory, tools, candidate, gh_json, feed), gh_json)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-dir", type=Path)
    parser.add_argument("--tools", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--refresh-channels", action="store_true", help="Retry feed publication for an already published release")
    args = parser.parse_args()
    if args.refresh_channels:
        refresh_channels(args.tools.resolve(), args.tag)
    else:
        if args.release_dir is None:
            parser.error("--release-dir is required when publishing a draft")
        publish(args.release_dir.resolve(), args.tools.resolve(), args.tag)
