#!/usr/bin/env python3
"""Fail when a prebuilt-binary pin lags its upstream release (#12197).

Checks the version in pkgs/<name>/hashes.json against the latest upstream:

- twg-cli: DEFAULT_VERSION in https://teamwork-graph.atlassian.com/cli/install
- codedb: tag_name of the latest GitHub release of justrach/codedb

Usage: python3 pkgs/pin-drift/check-pin-drift.py [--help] [--repo-root DIR]

Exit 0 when every pin matches upstream, 1 when one lags (naming the pin and
both versions), 2 for an invocation error or an unreadable pin or upstream.
Run it on a schedule, not in per-PR CI: it needs network access.
"""

import json
import re
import sys
import urllib.request
from pathlib import Path

TWG_INSTALLER = "https://teamwork-graph.atlassian.com/cli/install"
CODEDB_LATEST = "https://api.github.com/repos/justrach/codedb/releases/latest"


def fetch(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "check-pin-drift"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8")


def upstream_twg() -> str:
    match = re.search(r'DEFAULT_VERSION="?([0-9][0-9.]*)"?', fetch(TWG_INSTALLER))
    if match is None:
        raise ValueError("no DEFAULT_VERSION in the twg installer")
    return match.group(1)


def upstream_codedb() -> str:
    tag = json.loads(fetch(CODEDB_LATEST))["tag_name"]
    return tag.removeprefix("v")


PINS = {"twg-cli": upstream_twg, "codedb": upstream_codedb}


def usage() -> None:
    print(__doc__.strip())


def main(argv: list[str]) -> int:
    if argv[1:2] == ["--help"]:
        usage()
        return 0
    root = Path(__file__).resolve().parents[2]
    if argv[1:2] == ["--repo-root"] and len(argv) == 3:
        root = Path(argv[2])
    elif len(argv) > 1:
        print("check-pin-drift: error: unexpected arguments", file=sys.stderr)
        return 2

    drift = False
    for name, latest in PINS.items():
        path = root / "pkgs" / name / "hashes.json"
        try:
            pinned = json.loads(path.read_text())["version"]
        except (OSError, ValueError, KeyError) as exc:
            print(f"check-pin-drift: error: {path}: {exc}", file=sys.stderr)
            return 2
        try:
            upstream = latest()
        except (OSError, ValueError, KeyError) as exc:
            print(f"check-pin-drift: error: upstream for {name}: {exc}", file=sys.stderr)
            return 2
        if pinned != upstream:
            drift = True
            print(f"drift: {name} pinned {pinned}, upstream {upstream}", file=sys.stderr)
        else:
            print(f"ok: {name} {pinned}")
    return 1 if drift else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
