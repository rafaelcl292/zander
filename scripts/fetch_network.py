#!/usr/bin/env python3
"""Fetch the exact default network named by the pinned Stockfish reference."""
import hashlib
import pathlib
import re
import tempfile
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
header = (ROOT / "vendor/stockfish/src/evaluate.h").read_text()
name = re.search(r'#define EvalFileDefaultName "(nn-[0-9a-f]{12}\.nnue)"', header).group(1)
expected = name[3:15]
destination = ROOT / "networks" / name
destination.parent.mkdir(exist_ok=True)


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main():
    if destination.exists() and digest(destination).startswith(expected):
        print(destination)
        return
    urls = [
        f"https://tests.stockfishchess.org/api/nn/{name}",
        f"https://github.com/official-stockfish/networks/raw/master/{name}",
    ]
    for url in urls:
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temporary:
            path = pathlib.Path(temporary.name)
        try:
            print(f"Downloading {url}", flush=True)
            urllib.request.urlretrieve(url, path)
            checksum = digest(path)
            if not checksum.startswith(expected):
                raise ValueError(f"Network SHA-256 does not match {expected}: {checksum}")
            path.replace(destination)
            print(f"{checksum}  {destination.name}")
            return
        except (OSError, urllib.error.URLError, ValueError) as error:
            print(error, flush=True)
        finally:
            path.unlink(missing_ok=True)
    raise SystemExit("Could not fetch the pinned network")


if __name__ == "__main__":
    main()
