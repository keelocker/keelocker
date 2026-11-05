#!/usr/bin/env python3
"""Maintain the signed Stable/Beta appcast on the dedicated updates branch."""
import base64
import copy
import re
import xml.etree.ElementTree as ET

BRANCH = "updates"
FEED_URL = "https://raw.githubusercontent.com/keelocker/keelocker/updates/appcast.xml"
NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPOSITORY = "keelocker/keelocker"


def items(data):
    root = ET.fromstring(data)
    found = root.findall("./channel/item")
    if root.tag != "rss" or not 1 <= len(found) <= 2:
        raise ValueError("Expected one or two channel updates")
    result = {}
    versions = set()
    for item in found:
        channel_name = item.findtext(f"{{{NAMESPACE}}}channel")
        if channel_name not in (None, "beta"):
            raise ValueError("Stable updates must use Sparkle's default channel")
        lane = channel_name or "stable"
        version = item.findtext(f"{{{NAMESPACE}}}version", "")
        enclosure = item.find("enclosure")
        prefix = f"https://github.com/{REPOSITORY}/releases/download/"
        if lane not in ("stable", "beta") or lane in result or not re.fullmatch(r"[1-9][0-9]*", version):
            raise ValueError("Invalid or duplicate update channel/build")
        if version in versions or enclosure is None or not enclosure.get("url", "").startswith(prefix):
            raise ValueError("Invalid update archive identity")
        suffix = enclosure.get("url")[len(prefix):]
        match = re.fullmatch(r"(v?([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?))/KeeLocker-\2-universal\.dmg", suffix)
        if match is None or (("-" in match[2]) != (lane == "beta")):
            raise ValueError("Channel does not match the immutable archive tag")
        if len(base64.b64decode(enclosure.get(f"{{{NAMESPACE}}}edSignature", ""), validate=True)) != 64:
            raise ValueError("Missing archive signature")
        if not re.fullmatch(r"[1-9][0-9]*", enclosure.get("length", "")) or not item.findtext("description", "").strip():
            raise ValueError("Missing archive length or release notes")
        result[lane] = copy.deepcopy(item)
        versions.add(version)
    return result


def merge(previous, candidate):
    retained = items(previous) if previous is not None else {}
    incoming = items(candidate)
    if len(incoming) != 1:
        raise ValueError("A release must provide exactly one update")
    lane, item = next(iter(incoming.items()))
    build = int(item.findtext(f"{{{NAMESPACE}}}version"))
    def content(element):
        return (element.tag, element.text.strip() if element.text else "", sorted(element.attrib.items()),
                [content(child) for child in element])
    existing = retained.get(lane)
    if existing is not None and build == int(existing.findtext(f"{{{NAMESPACE}}}version")):
        # XML indentation and namespace prefixes do not change update content.
        if content(existing) != content(item):
            raise ValueError("A published build cannot change its feed content")
        return None
    for old in retained.values():
        old_build = int(old.findtext(f"{{{NAMESPACE}}}version"))
        if build <= old_build:
            raise ValueError("Build must exceed every published channel build")
    retained[lane] = item
    ET.register_namespace("sparkle", NAMESPACE)
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "KeeLocker Updates"
    for entry in sorted(retained.values(), key=lambda entry: int(entry.findtext(f"{{{NAMESPACE}}}version")), reverse=True):
        channel.append(entry)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def prepare(directory, tools, candidate, api, feed):
    feed.verify(tools, candidate)
    endpoint = f"repos/{REPOSITORY}"
    ref = api("api", f"{endpoint}/git/ref/heads/{BRANCH}", missing_ok=True)
    previous = None
    record = None
    if ref is not None:
        record = api("api", f"{endpoint}/contents/appcast.xml?ref={ref['object']['sha']}")
        previous = base64.b64decode(record["content"])
        prior = directory / "previous-channels.xml"
        prior.write_bytes(previous)
        feed.verify(tools, prior)
    merged = merge(previous, candidate.read_bytes())
    if merged is None:
        return None
    signed = directory / "channels.xml"
    signed.write_bytes(merged)
    feed.run_tool(tools, "sign_update", signed)
    feed.verify(tools, signed)
    items(signed.read_bytes())
    return {"content": signed.read_bytes(), "record": record}


def publish(prepared, api):
    if prepared is None:
        return
    endpoint = f"repos/{REPOSITORY}"
    content = prepared["content"]
    record = prepared["record"]
    if record is None:
        # Bootstrap an orphan branch containing only the signed appcast, never source/workflows.
        tree = api("api", f"{endpoint}/git/trees", payload={"tree": [
            {"path": "appcast.xml", "mode": "100644", "type": "blob", "content": content.decode("utf-8")}]})
        commit = api("api", f"{endpoint}/git/commits", payload={
            "message": "Publish signed update channels", "tree": tree["sha"], "parents": []})
        api("api", f"{endpoint}/git/refs", payload={"ref": f"refs/heads/{BRANCH}", "sha": commit["sha"]})
    else:
        api("api", f"{endpoint}/contents/appcast.xml", method="PUT", payload={
            "message": "Publish signed update channels", "branch": BRANCH, "sha": record["sha"],
            "content": base64.b64encode(content).decode("ascii")})
    readback = api("api", f"{endpoint}/contents/appcast.xml?ref={BRANCH}")
    if base64.b64decode(readback["content"]) != content:
        raise ValueError("Published channel feed readback differs")
    print(f"Verified signed update channels at {FEED_URL}")
