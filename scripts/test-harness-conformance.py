#!/usr/bin/env python3
"""Check the test-suite inventory and environment-sensitive test contracts.

Usage: test-harness-conformance.py REPOSITORY_ROOT
Accepts exactly one repository root before reading files or starting probes.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


def usage() -> int:
    print("usage: test-harness-conformance.py REPOSITORY_ROOT", file=sys.stderr)
    return 2


def candidate(path: Path, root: Path) -> bool:
    rel = path.relative_to(root).as_posix()
    return ".test." in path.name or (
        rel.startswith("pkgs/flake-tidy/tests/test_") and path.suffix == ".py"
    )


def suite_violations(text: str, path: str, production: dict[str, str]) -> set[str]:
    violations: set[str] = set()
    lines = text.splitlines()
    for line in lines[1:]:
        if re.match(r"^\s*#!\s*/usr/bin/env\b", line):
            violations.add("env-shebang-stub")
    for line in lines:
        if re.search(r"\b(?:printf|echo)\b[^\n]*#!\s*/usr/bin/env\b", line):
            violations.add("env-shebang-stub")
    if "/usr/bin/true" in text:
        violations.add("usr-bin-true-stub")

    if "--apply" in text:
        for name, source in production.items():
            if name in text and "check_not_running" in source:
                custom_ps = bool(re.search(r"(?:>|>>)[^\n]*/ps", text)) and "PATH=" in text
                if "harness_ps_double_begin" not in text and not custom_ps:
                    violations.add("apply-host-ps")
    return violations


def main() -> int:
    if len(sys.argv) != 2:
        return usage()
    root = Path(sys.argv[1]).resolve()
    inventory_path = root / "lib/test-suite-inventory.tsv"
    if not root.is_dir() or not inventory_path.is_file():
        print("test-harness-conformance: repository root or inventory is missing", file=sys.stderr)
        return 1

    failures: list[str] = []
    expected: set[str] = set()
    seen: set[str] = set()
    for number, raw in enumerate(inventory_path.read_text().splitlines(), 1):
        if not raw or raw.startswith("#"):
            continue
        fields = raw.split("\t", 2)
        if len(fields) != 3:
            failures.append(f"inventory line {number}: expected path, disposition, and reason")
            continue
        rel, disposition, reason = fields
        if rel in seen:
            failures.append(f"inventory line {number}: duplicate path {rel}")
        seen.add(rel)
        if disposition not in {"harness", "interpreter-named", "exempt-with-reason"}:
            failures.append(f"inventory line {number}: invalid disposition {disposition!r}")
        if disposition == "exempt-with-reason" and not reason.strip():
            failures.append(f"inventory line {number}: exemption for {rel} needs a reason")
        target = root / rel
        if not target.is_file():
            failures.append(f"inventory line {number}: listed file does not exist: {rel}")
        elif disposition == "harness" and "test-harness.sh" not in target.read_text(errors="replace"):
            failures.append(f"inventory line {number}: {rel} is marked harness but does not source it")
        expected.add(rel)

    actual = {p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file() and candidate(p, root)}
    for rel in sorted(actual - expected):
        failures.append(f"unclassified test suite: {rel}")
    for rel in sorted(expected - actual):
        failures.append(f"inventory entry is not a current suite: {rel}")

    production = {
        p.name: p.read_text(errors="replace")
        for p in root.rglob("*.sh")
        if ".test." not in p.name and "check_not_running" in p.read_text(errors="replace")
    }
    for rel in sorted(actual):
        path = root / rel
        if path.suffix != ".sh":
            continue
        for violation in sorted(suite_violations(path.read_text(errors="replace"), rel, production)):
            failures.append(f"{rel}: forbidden {violation}")

    # Synthetic offenders prove that each forbidden spelling trips the same
    # checks used for the repository inventory.
    probes = (
        ("env-shebang-stub", "cat >\"$bin/probe\" <<'EOF'\n#!/usr/bin/env bash\nEOF\n", {}),
        ("usr-bin-true-stub", "printf '#!/bin/sh\\n' >\"$bin/probe\"; /usr/bin/true\n", {}),
        ("apply-host-ps", "bash ./opencode-db-prune.sh --apply\n", {"opencode-db-prune.sh": "check_not_running"}),
    )
    for expected_violation, text, prod in probes:
        if expected_violation not in suite_violations(text, "synthetic.test.sh", prod):
            failures.append(f"synthetic probe did not catch {expected_violation}")

    if failures:
        print("test-harness-conformance: FAIL")
        for failure in failures:
            print(f" - {failure}")
        return 1

    probe = subprocess.run(
        ["bash", str(root / "lib/test-harness.test.sh")],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    print(probe.stdout, end="")
    if probe.returncode:
        print(f"test-harness-conformance: harness probe exited {probe.returncode}")
        return probe.returncode
    print(f"test-harness-conformance: PASS ({len(actual)} suites inventoried; all synthetic probes caught)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
