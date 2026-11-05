#!/usr/bin/env python3
"""Exercise signed channel selection/publication without GitHub writes."""
import base64
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("channels", Path(__file__).with_name("update-channels.py"))
channels = importlib.util.module_from_spec(spec)
spec.loader.exec_module(channels)


def candidate(build, beta=False, notes="Notes"):
    tag = f"0.1.0-beta.{build}" if beta else "0.1.0"
    root = ET.Element("rss")
    item = ET.SubElement(ET.SubElement(root, "channel"), "item")
    ET.SubElement(item, f"{{{channels.NAMESPACE}}}version").text = str(build)
    if beta:
        ET.SubElement(item, f"{{{channels.NAMESPACE}}}channel").text = "beta"
    ET.SubElement(item, "description").text = notes
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/keelocker/keelocker/releases/download/{tag}/KeeLocker-{tag}-universal.dmg",
        "length": "100", f"{{{channels.NAMESPACE}}}edSignature": base64.b64encode(bytes(64)).decode()})
    return ET.tostring(root)


class ChannelTests(unittest.TestCase):
    def test_beta_bootstrap_is_valid_without_stable_releases(self):
        data = channels.merge(None, candidate(4, beta=True))
        self.assertEqual(set(channels.items(data)), {"beta"})
        self.assertEqual([item for item in channels.items(data).values()
                          if item.find(f"{{{channels.NAMESPACE}}}channel") is None], [])

    def test_beta_preserves_stable_and_stable_preserves_beta(self):
        first = channels.merge(None, candidate(4))
        both = channels.merge(first, candidate(5, beta=True))
        self.assertEqual(set(channels.items(both)), {"stable", "beta"})
        newest = channels.merge(both, candidate(6))
        entries = channels.items(newest)
        self.assertEqual(entries["stable"].findtext(f"{{{channels.NAMESPACE}}}version"), "6")
        self.assertEqual(entries["beta"].findtext(f"{{{channels.NAMESPACE}}}version"), "5")
        self.assertIsNone(entries["stable"].find(f"{{{channels.NAMESPACE}}}channel"))

    def test_build_must_increase_across_both_channels(self):
        previous = channels.merge(candidate(4), candidate(7, beta=True))
        for data in (candidate(6), candidate(7), candidate(3, beta=True)):
            with self.assertRaises(ValueError):
                channels.merge(previous, data)

    def test_identical_retry_is_noop_even_after_other_channel_advanced(self):
        stable = candidate(4)
        previous = channels.merge(stable, candidate(5, beta=True))
        self.assertIsNone(channels.merge(previous, stable))
        with self.assertRaises(ValueError):
            channels.merge(previous, candidate(4, notes="Changed"))

    def test_reject_mislabeled_beta_unknown_channels_and_archive_hosts(self):
        for kind in ("missing", "unknown", "host", "signature", "duplicate"):
            root = ET.fromstring(candidate(5, beta=True))
            item = root.find("./channel/item")
            if kind == "missing":
                item.remove(item.find(f"{{{channels.NAMESPACE}}}channel"))
            elif kind == "unknown":
                item.find(f"{{{channels.NAMESPACE}}}channel").text = "nightly"
            elif kind == "host":
                item.find("enclosure").set("url", "https://example.invalid/app.dmg")
            elif kind == "signature":
                item.find("enclosure").set(f"{{{channels.NAMESPACE}}}edSignature", "")
            else:
                root.find("channel").append(item)
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                channels.items(ET.tostring(root))

    def test_existing_feed_is_verified_before_merging(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / "candidate.xml"
            path.write_bytes(candidate(5, beta=True))
            feed = Mock()
            api = Mock(side_effect=[{"object": {"sha": "commit"}}, {
                "sha": "blob", "content": base64.b64encode(candidate(4)).decode()}])
            result = channels.prepare(directory, directory, path, api, feed)
            self.assertEqual(feed.verify.call_count, 3)
            self.assertEqual(set(channels.items(result["content"])), {"stable", "beta"})
            self.assertEqual(result["record"]["sha"], "blob")
            api.side_effect = [{"object": {"sha": "commit"}}, {
                "sha": "blob", "content": base64.b64encode(candidate(4)).decode()}]
            feed.verify.side_effect = [None, ValueError("invalid prior signature")]
            with self.assertRaises(ValueError):
                channels.prepare(directory, directory, path, api, feed)

    def test_atomic_branch_bootstrap_and_exact_readback(self):
        data = channels.merge(None, candidate(4, beta=True))
        api = Mock(side_effect=[{"sha": "tree"}, {"sha": "commit"}, {}, {
            "content": base64.b64encode(data).decode()}])
        channels.publish({"content": data, "record": None}, api)
        self.assertEqual(api.call_args_list[1].kwargs["payload"]["parents"], [])
        self.assertEqual(api.call_args_list[2].kwargs["payload"]["ref"], "refs/heads/updates")

    def test_update_uses_blob_sha_and_rejects_bad_readback(self):
        data = channels.merge(None, candidate(4))
        api = Mock(side_effect=[{}, {"content": base64.b64encode(b"wrong").decode()}])
        with self.assertRaises(ValueError):
            channels.publish({"content": data, "record": {"sha": "expected-blob"}}, api)
        self.assertEqual(api.call_args_list[0].kwargs["payload"]["sha"], "expected-blob")
        self.assertEqual(api.call_args_list[0].kwargs["method"], "PUT")


if __name__ == "__main__":
    unittest.main()
