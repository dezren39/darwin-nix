#!/usr/bin/env python3
"""Fail when the twg-cli or codedb pin lags its upstream release (#2039).

- pkgs/twg-cli/hashes.json (`version`) is compared with DEFAULT_VERSION in
  the official installer, https://teamwork-graph.atlassian.com/cli/install.
- pkgs/codedb/hashes.json (`version`) is compared with the latest release
  tag of justrach/codedb, read with `gh release view`.

Usage: python3 pkgs/check-tool-pins.py [--help] [--repo-root DIR]

Exit 0 when both pins match upstream, 1 (naming each drifted pin, its
pinned and upstream version) on drift, 2 for an invocation error: a bad
argument, a pin file missing, unreadable, or malformed, or upstream that
cannot be read. Invocation errors are one line on stderr naming the file.
"""

import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

INSTALLER_URL = "https://teamwork-graph.atlassian.com/cli/install"
CODEDB_REPO = "justrach/codedb"
GH_TIMEOUT_S = 30
PINS = {
    "twg-cli": Path("pkgs/twg-cli/hashes.json"),
    "codedb": Path("pkgs/codedb/hashes.json"),
}


class InvocationError(Exception):
    pass


def pinned_version(root: Path, rel: Path) -> str:
    path = root / rel
    try:
        data = json.loads(path.read_text())
    except OSError as exc:
        raise InvocationError(f"{rel}: {exc.strerror or exc}")
    except UnicodeDecodeError as exc:
        raise InvocationError(f"{rel}: not valid UTF-8: {exc}")
    except ValueError as exc:
        raise InvocationError(f"{rel}: invalid JSON: {exc}")
    if not isinstance(data, dict):
        raise InvocationError(f"{rel}: expected a JSON object")
    version = data.get("version")
    if not isinstance(version, str) or not version:
        raise InvocationError(f"{rel}: 'version' must be a non-empty string")
    return version


def twg_upstream() -> str:
    try:
        with urllib.request.urlopen(INSTALLER_URL, timeout=30) as resp:
            text = resp.read().decode("utf-8", "replace")
    except OSError as exc:
        raise InvocationError(f"cannot read twg installer: {exc}")
    match = re.search(r'^DEFAULT_VERSION="([^"]+)"', text, re.MULTILINE)
    if match is None:
        raise InvocationError("twg installer has no DEFAULT_VERSION")
    return match.group(1)


def codedb_upstream(timeout=GH_TIMEOUT_S) -> str:
    try:
        proc = subprocess.run(
            ["gh", "release", "view", "--repo", CODEDB_REPO, "--json", "tagName",
             "--jq", ".tagName"],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise InvocationError(
            f"cannot read latest codedb release: gh release view --repo "
            f"{CODEDB_REPO} timed out after {timeout}s"
        )
    except OSError as exc:
        raise InvocationError(f"cannot read latest codedb release: {exc}")
    tag = proc.stdout.strip()
    if proc.returncode != 0 or not tag:
        raise InvocationError(f"cannot read latest codedb release: {proc.stderr.strip()}")
    return tag.removeprefix("v")


def usage() -> str:
    return f"usage: {sys.argv[0]} [--repo-root DIR]"


def main(args=None) -> int:
    if args is None:
        args = sys.argv[1:]
    if args in (["--help"], ["-h"]):
        print(usage())
        print("Exit 0 = pins current, 1 = drift, 2 = invocation error.")
        return 0
    if args[:1] == ["--repo-root"] and len(args) == 2:
        if args[1] == "":
            print("check-tool-pins: error: empty --repo-root argument", file=sys.stderr)
            print(usage(), file=sys.stderr)
            return 2
        root = Path(args[1])
    elif args:
        print(usage(), file=sys.stderr)
        return 2
    else:
        root = Path(__file__).resolve().parents[1]

    try:
        pinned = {name: pinned_version(root, rel) for name, rel in PINS.items()}
        upstream = {"twg-cli": twg_upstream(), "codedb": codedb_upstream()}
    except InvocationError as exc:
        print(f"check-tool-pins: error: {exc}", file=sys.stderr)
        return 2

    drifted = [name for name in PINS if pinned[name] != upstream[name]]
    if drifted:
        print("tool pins behind upstream:", file=sys.stderr)
        for name in drifted:
            print(
                f"  - {name}: pinned {pinned[name]} in {PINS[name]}, "
                f"upstream is {upstream[name]}",
                file=sys.stderr,
            )
        print(
            "Bump the version and the hashes together (see the package's "
            "hashes.json), then rerun this check.",
            file=sys.stderr,
        )
        return 1

    for name in PINS:
        print(f"{name} pin current: {pinned[name]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
