#!/usr/bin/env python3
"""Add one signed release archive to the verified distribution feed."""
import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPOSITORY = "https://github.com/pachi-33/Mindscape"
ET.register_namespace("sparkle", SPARKLE)


def sparkle(name):
    return f"{{{SPARKLE}}}{name}"


def update_feed(args):
    version = args.version
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?", version):
        raise SystemExit("Invalid release version")
    if args.build <= 0 or args.archive.name != f"Mindscape-{version}.zip":
        raise SystemExit("The build number and ZIP filename must match the release")
    if not re.fullmatch(r"[0-9]+(\.[0-9]+){1,2}", args.minimum_system):
        raise SystemExit("Invalid minimum macOS version")

    signing = [str(args.sign_tool)]
    if args.account:
        signing += ["--account", args.account]
    else:
        signing += ["--ed-key-file", str(args.test_key_file)]
    if args.previous:
        subprocess.run([*signing, "--verify", str(args.previous)], check=True)
        root = ET.parse(args.previous).getroot()
    else:
        root = ET.Element("rss", version="2.0")
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Mindscape Updates"
    channel = root.find("channel")
    if root.tag != "rss" or channel is None:
        raise SystemExit("Invalid existing appcast")

    for old in channel.findall("item"):
        number = int(old.findtext(sparkle("version")))
        display = old.findtext(sparkle("shortVersionString"))
        if number >= args.build or display == version:
            raise SystemExit("Use a new release version and a build number greater than all published builds")

    signature = subprocess.check_output([*signing, "-p", str(args.archive)], text=True).strip()
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise SystemExit("Sparkle returned an invalid archive signature")
    subprocess.run([*signing, "--verify", str(args.archive), signature], check=True)

    item = ET.Element("item")
    channel.insert(1, item)
    ET.SubElement(item, "title").text = f"Mindscape {version}"
    ET.SubElement(item, "link").text = f"{REPOSITORY}/releases/tag/v{version}"
    ET.SubElement(item, "description", {sparkle("format"): "plain-text"}).text = args.notes.read_text()
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, sparkle("version")).text = str(args.build)
    ET.SubElement(item, sparkle("shortVersionString")).text = version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.minimum_system
    if "-" in version:
        ET.SubElement(item, sparkle("channel")).text = "beta"
    ET.SubElement(item, "enclosure", {
        "url": f"{REPOSITORY}/releases/download/v{version}/{args.archive.name}",
        "length": str(args.archive.stat().st_size),
        "type": "application/octet-stream",
        sparkle("edSignature"): signature,
    })

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output.parent) as tmp:
        candidate = Path(tmp) / "appcast.xml"
        ET.indent(root)
        ET.ElementTree(root).write(candidate, encoding="utf-8", xml_declaration=True)
        subprocess.run([*signing, str(candidate)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([*signing, "--verify", str(candidate)], check=True)
        candidate.replace(args.output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--notes", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--minimum-system", required=True)
    parser.add_argument("--sign-tool", type=Path, required=True)
    signing = parser.add_mutually_exclusive_group(required=True)
    signing.add_argument("--account")
    signing.add_argument("--test-key-file", type=Path)
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    update_feed(parser.parse_args())
