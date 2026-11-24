#!/usr/bin/env python3
"""Verify that the published GitHub archive is publicly downloadable and byte identical."""
import argparse
import filecmp
from pathlib import Path
import subprocess

REPOSITORY = "https://github.com/pachi-33/Mindscape"


def verify(archive, version, destination):
    if archive.name != f"Mindscape-{version}.zip":
        raise ValueError("Release archive filename does not match the tag")
    asset_url = f"{REPOSITORY}/releases/download/v{version}/{archive.name}"
    subprocess.run([
        "curl", "--fail", "--silent", "--show-error", "--location",
        "--proto", "=https", "--proto-redir", "=https",
        "--retry", "6", "--retry-connrefused", "--max-time", "180",
        "--output", str(destination), asset_url,
    ], check=True)
    if not filecmp.cmp(archive, destination, shallow=False):
        raise ValueError("Published asset differs from the signed archive")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("version")
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    verify(args.archive, args.version, args.destination)
