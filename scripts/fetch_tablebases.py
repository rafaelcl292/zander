#!/usr/bin/env python3
"""Fetch small Syzygy regression tables from a pinned python-chess revision."""
import hashlib
import json
import pathlib
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / "tests/syzygy_manifest.json").read_text())
destination = ROOT / "artifacts/syzygy"
destination.mkdir(parents=True, exist_ok=True)
for entry in manifest["files"]:
    path = destination / entry["name"]
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"]:
        continue
    url = f"https://raw.githubusercontent.com/niklasf/python-chess/{manifest['revision']}/data/syzygy/regular/{entry['name']}"
    data = urllib.request.urlopen(url, timeout=60).read()
    if len(data) != entry["size"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise ValueError(f"Unexpected tablebase contents: {entry['name']}")
    path.write_bytes(data)
print(destination)
