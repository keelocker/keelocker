#!/usr/bin/env python3
"""Exercise feed validation using synthetic XML and archives only."""
import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest
import sys
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("feed", Path(__file__).with_name("generate-update-feed.py"))
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)


class FeedTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.archive = Path(self.directory.name) / "synthetic.dmg"
        self.archive.write_bytes(b"synthetic encrypted application archive")
        self.url = "https://github.com/keelocker/keelocker/releases/download/v0.2.0/synthetic.dmg"
        self.info = {"CFBundleVersion": "3"}
        self.xml = ET.fromstring(f"""<rss xmlns:sparkle="{feed.NAMESPACE}"><channel><item>
          <sparkle:version>3</sparkle:version>
          <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
          <description>Synthetic release notes</description>
          <enclosure url="{self.url}" length="{self.archive.stat().st_size}"
            sparkle:edSignature="{base64.b64encode(bytes(64)).decode()}"/>
          </item></channel></rss>""")

    def validate(self):
        return feed.validate_feed(ET.tostring(self.xml), self.archive, self.info, self.url)

    def test_matching_metadata(self):
        self.assertTrue(self.validate())

    def test_missing_signature(self):
        self.xml.find("./channel/item/enclosure").attrib.pop(f"{{{feed.NAMESPACE}}}edSignature")
        with self.assertRaises(ValueError):
            self.validate()

    def test_wrong_host(self):
        self.xml.find("./channel/item/enclosure").set("url", "https://example.invalid/update.dmg")
        with self.assertRaises(ValueError):
            self.validate()

    def test_truncated_archive(self):
        self.archive.write_bytes(b"truncated")
        with self.assertRaises(ValueError):
            self.validate()

    def test_wrong_build(self):
        self.info["CFBundleVersion"] = "4"
        with self.assertRaises(ValueError):
            self.validate()

    def test_missing_notes(self):
        item = self.xml.find("./channel/item")
        item.remove(item.find("description"))
        with self.assertRaises(ValueError):
            self.validate()

    def test_multiple_items(self):
        self.xml.find("channel").append(ET.Element("item"))
        with self.assertRaises(ValueError):
            self.validate()


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.info = {"CFBundleVersion": "3", "CFBundleShortVersionString": "0.1.0"}
        self.release = {"tag_name": "v0.1.0", "draft": True, "prerelease": False, "body": "Signed updates"}

    def validate(self):
        return feed.validate_release(self.info, self.release, "keelocker/keelocker")

    def test_stable_draft(self):
        self.assertEqual(self.validate(), "0.1.0")
        self.release["tag_name"] = "0.1.0"
        self.assertEqual(self.validate(), "0.1.0")

    def test_published_release_is_rejected(self):
        self.release["draft"] = False
        with self.assertRaises(ValueError):
            self.validate()

    def test_beta_must_be_prerelease(self):
        self.release["tag_name"] = "v0.1.0-beta.1"
        with self.assertRaises(ValueError):
            self.validate()
        self.release["prerelease"] = True
        self.assertEqual(self.validate(), "0.1.0-beta.1")

    def test_stable_cannot_hide_in_prerelease(self):
        self.release["prerelease"] = True
        with self.assertRaises(ValueError):
            self.validate()

    def test_version_and_build_must_match(self):
        self.info["CFBundleShortVersionString"] = "0.2.0"
        with self.assertRaises(ValueError):
            self.validate()
        self.info["CFBundleShortVersionString"] = "0.1.0"
        for invalid in ("0", "-1", "2.3", "beta"):
            self.info["CFBundleVersion"] = invalid
            with self.assertRaises(ValueError):
                self.validate()

    def test_empty_notes_and_other_repository_are_rejected(self):
        self.release["body"] = " "
        with self.assertRaises(ValueError):
            self.validate()
        self.release["body"] = "Signed updates"
        with self.assertRaises(ValueError):
            feed.validate_release(self.info, self.release, "another/repository")


if __name__ == "__main__":
    unittest.main()
