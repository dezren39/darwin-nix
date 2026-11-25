#!/usr/bin/env python3
"""Probes for check-tool-pins.py (#2039). Offline: upstream lookups are stubbed.

Run: python3 pkgs/check-tool-pins.test.py  (exit 0 = all probes passed)
"""

import importlib.util
import io
import json
import os
import sys
import tempfile
import time
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("check_tool_pins", HERE / "check-tool-pins.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Captured before any probe stubs the module attributes: run() replaces
# mod.codedb_upstream with a zero-argument lambda, so a later probe that
# reads the attribute back would get the stub, not the real function.
REAL_TWG_UPSTREAM = mod.twg_upstream
REAL_CODEDB_UPSTREAM = mod.codedb_upstream

FAILURES = []


def check(name, ok, detail=""):
    if ok:
        print(f"ok: {name}")
    else:
        FAILURES.append(name)
        print(f"FAIL: {name} {detail}")


def make_repo(twg, codedb):
    root = Path(tempfile.mkdtemp())
    for name, version in (("twg-cli", twg), ("codedb", codedb)):
        d = root / "pkgs" / name
        d.mkdir(parents=True)
        if version is None:
            (d / "hashes.json").write_text("[]")
        else:
            (d / "hashes.json").write_text(json.dumps({"version": version, "hashes": {}}))
    return root


def run(root, upstream_twg, upstream_codedb):
    mod.twg_upstream = lambda: upstream_twg
    mod.codedb_upstream = lambda: upstream_codedb
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = mod.main(["--repo-root", str(root)])
    return code, out.getvalue(), err.getvalue()


def main_probes():
    root = make_repo("1.4.6", "0.2.5864")
    code, out, _ = run(root, "1.4.6", "0.2.5864")
    check("current pins exit 0", code == 0, f"got {code}")
    check("current pins name both tools", "twg-cli" in out and "codedb" in out, out)

    code, _, err = run(root, "1.4.7", "0.2.5864")
    check("twg drift exits 1", code == 1, f"got {code}")
    check("twg drift names pinned and upstream", "twg-cli: pinned 1.4.6" in err and "upstream is 1.4.7" in err, err)

    code, _, err = run(root, "1.4.6", "0.2.5900")
    check("codedb drift exits 1", code == 1, f"got {code}")
    check("codedb drift names codedb", "codedb: pinned 0.2.5864" in err, err)

    bad = make_repo("1.4.6", None)
    code, _, err = run(bad, "1.4.6", "0.2.5864")
    check("non-object pin exits 2", code == 2, f"got {code}")
    check("non-object pin names the file", "pkgs/codedb/hashes.json" in err, err)

    missing = Path(tempfile.mkdtemp())
    code, _, err = run(missing, "1.4.6", "0.2.5864")
    check("missing pin files exit 2", code == 2, f"got {code}")
    check("missing pin names the file", "hashes.json" in err and "Traceback" not in err, err)

    with redirect_stderr(io.StringIO()):
        code = mod.main(["--bogus"])
    check("unknown argument exits 2", code == 2, f"got {code}")


def fake_gh(script):
    bindir = Path(tempfile.mkdtemp())
    gh = bindir / "gh"
    gh.write_text(script)
    gh.chmod(0o755)
    return bindir


def timeout_probes():
    real_upstream = REAL_CODEDB_UPSTREAM
    old_path = os.environ["PATH"]
    try:
        # A gh that sleeps 10s must be cut off by the lookup's own bound:
        # InvocationError naming the codedb lookup, well before 10s.
        os.environ["PATH"] = str(fake_gh("#!/bin/sh\nsleep 10\n")) + os.pathsep + old_path
        started = time.monotonic()
        try:
            real_upstream(timeout=1)
            raised = None
        except mod.InvocationError as exc:
            raised = exc
        elapsed = time.monotonic() - started
        check("sleeping gh raises InvocationError", raised is not None)
        check(
            "timeout error names the codedb lookup",
            raised is not None and "codedb" in str(raised) and "timed out" in str(raised),
            str(raised),
        )
        check("timeout bound fires before the sleep ends", elapsed < 8, f"{elapsed:.1f}s")

        # Control: a gh that answers at once still yields its tag.
        os.environ["PATH"] = str(fake_gh("#!/bin/sh\necho v9.9.9\n")) + os.pathsep + old_path
        tag = real_upstream(timeout=5)
        check("answering gh returns its tag", tag == "9.9.9", tag)

        # End to end: main reports the timeout as exit 2, one line, no traceback.
        os.environ["PATH"] = str(fake_gh("#!/bin/sh\nsleep 10\n")) + os.pathsep + old_path
        root = make_repo("1.4.6", "0.2.5864")
        mod.twg_upstream = lambda: "1.4.6"
        mod.codedb_upstream = lambda: real_upstream(timeout=1)
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = mod.main(["--repo-root", str(root)])
        check("main exits 2 on lookup timeout", code == 2, f"got {code}")
        check(
            "main timeout line names codedb without a traceback",
            "codedb" in err.getvalue() and "Traceback" not in err.getvalue(),
            err.getvalue(),
        )
    finally:
        os.environ["PATH"] = old_path
        mod.twg_upstream = REAL_TWG_UPSTREAM
        mod.codedb_upstream = REAL_CODEDB_UPSTREAM


if __name__ == "__main__":
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    main_probes()
    timeout_probes()
    if FAILURES:
        print(f"{len(FAILURES)} probe(s) failed")
        sys.exit(1)
    print("all probes passed")
