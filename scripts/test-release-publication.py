#!/usr/bin/env python3
"""Release workflow and publication regressions; no GitHub writes."""
from pathlib import Path
import hashlib
import importlib.util
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("publication", ROOT / "scripts/publish-update.py")
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


class WorkflowTests(unittest.TestCase):
    def test_only_explicit_dispatch_can_start_publication(self):
        trigger = (ROOT / ".github/workflows/release.yml").read_text().split("\njobs:", 1)[0]
        self.assertRegex(trigger, r"(?m)^  workflow_dispatch:")
        self.assertNotRegex(trigger, r"(?m)^  release:")


class DraftLookupTests(unittest.TestCase):
    def test_draft_lookup_uses_cli_and_subsequent_reads_use_database_id(self):
        result = subprocess.CompletedProcess([], 0, json.dumps({"databaseId": 42}), "")
        with patch.object(publication.subprocess, "run", return_value=result) as run:
            endpoint = publication.release_endpoint("keelocker/keelocker", "0.1.0-beta.3")
        self.assertEqual(endpoint, "repos/keelocker/keelocker/releases/42")
        self.assertEqual(run.call_args.args[0], ["gh", "release", "view", "0.1.0-beta.3",
                         "--repo", "keelocker/keelocker", "--json", "databaseId"])

    def test_incomplete_assets_block_publication(self):
        with self.assertRaises(ValueError):
            publication.asset_names({"assets": [{"name": "archive.dmg", "state": "starter"}]})


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.local = self.directory / "build"
        (self.local / "KeeLocker.app/Contents").mkdir(parents=True)
        self.info = {"CFBundleVersion": "3", "CFBundleShortVersionString": "0.1.0",
                     "CFBundleIdentifier": "com.keelocker.desktop"}
        (self.local / "KeeLocker.app/Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        self.name = "KeeLocker-0.1.0-universal.dmg"
        (self.local / self.name).write_bytes(b"new rebuild differs from previously uploaded archive")
        self.remote = {}
        self.release = {"id": 42, "tag_name": "v0.1.0", "draft": True, "prerelease": False,
                        "body": "Signed updates", "target_commitish": "reviewed"}
        self.latest = None
        self.fail_upload = None
        self.generated_archives = []
        self.calls = []

    def metadata(self):
        return dict(self.release, assets=[{"name": name, "state": "uploaded"} for name in self.remote])

    def gh(self, *args, **kwargs):
        self.calls.append(args)
        if args[:2] == ("release", "view"):
            return {"databaseId": 42}
        if "/releases/tags/" in args[1]:
            raise AssertionError("The REST tag lookup cannot retrieve drafts")
        if args[1].endswith("/latest"):
            return self.latest
        return self.metadata()

    def run_command(self, command, **kwargs):
        self.calls.append(tuple(command))
        if command[0] == "gh":
            if command[2] == "download":
                name = command[command.index("--pattern") + 1]
                Path(command[command.index("--dir") + 1], name).write_bytes(self.remote[name])
            elif command[2] == "upload":
                file = Path(command[4])
                if self.fail_upload == file.name:
                    raise subprocess.CalledProcessError(1, command)
                if file.name in self.remote:
                    raise AssertionError("Attempted to overwrite an existing asset")
                self.remote[file.name] = file.read_bytes()
            elif command[2] == "edit":
                if set(self.remote) != {self.name, "SHA256SUMS.txt", "appcast.xml"}:
                    raise AssertionError("Published incomplete release")
                self.release["draft"] = False
        elif command[0] == "hdiutil" and command[1] == "attach":
            mount = Path(command[command.index("-mountpoint") + 1])
            (mount / "KeeLocker.app/Contents").mkdir(parents=True)
            (mount / "KeeLocker.app/Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        elif command[0] == "ditto":
            shutil.copytree(command[1], command[2])
        return subprocess.CompletedProcess(command, 0)

    def generate(self, directory, tools, event):
        archive = directory / self.name
        self.generated_archives.append(archive.read_bytes())
        (directory / "appcast.xml").write_bytes(b"synthetic signed feed")

    def publish(self):
        with patch.object(publication, "gh_json", side_effect=self.gh), \
             patch.object(publication.subprocess, "run", side_effect=self.run_command), \
             patch.object(publication.feed, "generate", side_effect=self.generate), \
             patch.object(publication.feed, "verify"), \
             patch.object(publication.feed, "validate_feed", return_value="signature"):
            publication.publish(self.local, self.directory / "tools", self.release["tag_name"])

    def test_fresh_draft_is_published_only_after_all_assets_are_read_back(self):
        self.publish()
        self.assertFalse(self.release["draft"])
        edits = [i for i, call in enumerate(self.calls) if call[:3] == ("gh", "release", "edit")]
        downloads = [i for i, call in enumerate(self.calls) if call[:3] == ("gh", "release", "download")]
        self.assertEqual(len(edits), 1)
        self.assertEqual(len(downloads), 3)
        self.assertGreater(edits[0], max(downloads))

    def test_feed_upload_failure_keeps_draft_and_rerun_uses_exact_existing_archive(self):
        self.fail_upload = "appcast.xml"
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertTrue(self.release["draft"])
        published_bytes = self.remote[self.name]
        (self.local / self.name).write_bytes(b"another rebuilt archive")
        self.fail_upload = None
        self.publish()
        self.assertEqual(self.remote[self.name], published_bytes)
        self.assertEqual(self.generated_archives[-1], published_bytes)
        self.assertFalse(self.release["draft"])

    def test_checksum_upload_failure_can_be_resumed(self):
        self.fail_upload = "SHA256SUMS.txt"
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertEqual(set(self.remote), {self.name})
        self.fail_upload = None
        self.publish()
        self.assertFalse(self.release["draft"])

    def test_prerelease_is_published_without_replacing_latest(self):
        old_name = self.name
        self.name = "KeeLocker-0.1.0-beta.3-universal.dmg"
        (self.local / old_name).rename(self.local / self.name)
        self.release.update(tag_name="0.1.0-beta.3", prerelease=True)
        self.publish()
        edit = next(call for call in self.calls if call[:3] == ("gh", "release", "edit"))
        self.assertIn("--latest=false", edit)
        self.assertFalse(self.release["draft"])

    def test_bad_existing_checksum_does_not_publish_or_replace_archive(self):
        self.remote[self.name] = b"already uploaded"
        self.remote["SHA256SUMS.txt"] = b"bad checksum"
        before = dict(self.remote)
        with self.assertRaises(ValueError):
            self.publish()
        self.assertEqual(before, self.remote)
        self.assertTrue(self.release["draft"])

    def test_an_existing_complete_feed_is_verified_and_reused(self):
        self.remote[self.name] = b"existing archive"
        digest = hashlib.sha256(self.remote[self.name]).hexdigest()
        self.remote["SHA256SUMS.txt"] = f"{digest}  {self.name}\n".encode()
        self.remote["appcast.xml"] = b"existing signed feed"
        self.publish()
        self.assertEqual(self.remote["appcast.xml"], b"existing signed feed")
        self.assertFalse(self.release["draft"])

    def test_metadata_change_during_upload_prevents_publication(self):
        original = self.generate
        def change(*args):
            original(*args)
            self.release["body"] = "changed notes"
        self.generate = change
        with self.assertRaises(ValueError):
            self.publish()
        self.assertTrue(self.release["draft"])
        self.assertFalse(self.remote)

    def test_older_or_equal_build_does_not_replace_latest(self):
        self.latest = {"tag_name": "v0.0.9", "assets": [{"name": "appcast.xml", "state": "uploaded"}]}
        self.remote["appcast.xml"] = b'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>3</sparkle:version></item></channel></rss>'
        with self.assertRaises(ValueError):
            self.publish()
        self.assertTrue(self.release["draft"])


if __name__ == "__main__":
    unittest.main()
