#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Temp-HOME probes for browser-remote-debug.py.

Covers:
1. CLI argument contract: --help/-h prints usage at exit 0 without touching
   seeded files; unknown arguments and repeated --dry-run exit 2 naming the
   offending argument without touching seeded files.
2. Happy path + idempotence + key/mode preservation: Chrome, Helium and Edge
   Local State files gain devtools.remote_debugging.user-enabled = true while
   preserving existing top-level keys, nested devtools keys, Unicode data and
   file mode (0600); a second run is a byte-for-byte no-op with empty stdout.
3. --dry-run reports changes at exit 0 without modifying files on disk.
4. Running-browser skip: a live SingletonSocket or a live same-host
   SingletonLock PID skips that browser at exit 0 without modifying its Local
   State, while other idle browsers in the same run are still updated.
5. Stale lock/socket recovery: a dead same-host SingletonLock PID and an
   ECONNREFUSED SingletonSocket from a crashed browser are recognized as stale
   and do NOT block updating Local State.
6. Per-browser failure isolation: malformed JSON, non-object top-level JSON,
   non-object devtools/remote_debugging, or a dangling Local State symlink
   leaves that file untouched, still updates the healthy browsers, names the
   failed browsers on stderr, and exits 1 without leaking Local State content.
7. Symlink preservation: when Local State is a symlink, temp+rename updates the
   resolved target in place and keeps the symlink intact.

Run: python3 browser-remote-debug.test.py  (exit 0 = all probes passed)
"""

import json
import os
import socket
import stat
import subprocess
import sys
import tempfile

SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "browser-remote-debug.py"
)
FAILURES = []

CHROME_REL = "Library/Application Support/Google/Chrome"
HELIUM_REL = "Library/Application Support/net.imput.helium"
EDGE_REL = "Library/Application Support/Microsoft Edge"


def check(name, cond, detail=""):
    if cond:
        print(f"PASS: {name}")
    else:
        msg = f"FAIL: {name}" + (f" ({detail})" if detail else "")
        print(msg, file=sys.stderr)
        FAILURES.append(msg)


def run_script(home, *args):
    env = dict(os.environ, HOME=home)
    return subprocess.run(
        [sys.executable, SCRIPT, *args],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def seed_local_state(home, rel_dir, content, mode=0o600):
    d = os.path.join(home, rel_dir)
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "Local State")
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.chmod(p, mode)
    return p


def test_cli_contract(root):
    home = os.path.join(root, "cli")
    sentinel = '{"profile":{"info_cache":{"Default":{"name":"Drew Secret Token"}}}}'
    p = seed_local_state(home, CHROME_REL, sentinel)

    for flag in ("--help", "-h"):
        r = run_script(home, flag)
        check(f"{flag} exits 0", r.returncode == 0, f"rc={r.returncode}")
        check(f"{flag} prints usage on stdout", "usage: browser-remote-debug.py" in r.stdout)
        check(f"{flag} leaves Local State untouched", open(p).read() == sentinel)

    for bad_args, want in [
        (["--bogus"], "--bogus"),
        (["--dry-run", "--dry-run"], "--dry-run"),
        (["--help", "--dry-run"], "--help"),
        (["extra"], "extra"),
    ]:
        r = run_script(home, *bad_args)
        label = " ".join(bad_args)
        check(f"bad args ({label}) exits 2", r.returncode == 2, f"rc={r.returncode}")
        check(
            f"bad args ({label}) names {want} on stderr",
            want in r.stderr and "usage:" in r.stderr,
            r.stderr,
        )
        check(f"bad args ({label}) leaves Local State untouched", open(p).read() == sentinel)


def test_happy_idempotent_and_dry_run(root):
    home = os.path.join(root, "happy")
    chrome_ls = seed_local_state(
        home,
        CHROME_REL,
        json.dumps(
            {
                "os_crypt": {"encrypted_key": "secret-do-not-print"},
                "devtools": {"other_setting": 42, "remote_debugging": {"allowed": True}},
                "unicode_note": "café",
            }
        ),
        mode=0o600,
    )
    helium_ls = seed_local_state(
        home, HELIUM_REL, json.dumps({"browser": {"enabled_labs_experiments": []}}), mode=0o640
    )
    # Edge directory exists with no Local State yet (never launched) -> untouched, no file created.
    edge_dir = os.path.join(home, EDGE_REL)
    os.makedirs(edge_dir, exist_ok=True)

    # Dry run first: reports Chrome + Helium, writes nothing.
    dry = run_script(home, "--dry-run")
    check("dry-run exits 0", dry.returncode == 0, dry.stderr)
    check("dry-run mentions Google Chrome", "Google Chrome" in dry.stdout and "(dry run)" in dry.stdout)
    check("dry-run mentions Helium", "Helium" in dry.stdout)
    check("dry-run never prints file secret", "secret-do-not-print" not in dry.stdout + dry.stderr)
    check(
        "dry-run leaves Chrome unset",
        "user-enabled" not in json.load(open(chrome_ls))["devtools"]["remote_debugging"],
    )

    # Real run: updates Chrome + Helium, skips Edge without creating Local State.
    res = run_script(home)
    check("real run exits 0", res.returncode == 0, res.stderr)
    check("real run never prints file secret", "secret-do-not-print" not in res.stdout + res.stderr)
    chrome_data = json.load(open(chrome_ls, encoding="utf-8"))
    helium_data = json.load(open(helium_ls, encoding="utf-8"))
    check(
        "Chrome user-enabled is True",
        chrome_data["devtools"]["remote_debugging"]["user-enabled"] is True,
    )
    check(
        "Chrome sibling keys preserved",
        chrome_data["devtools"]["other_setting"] == 42
        and chrome_data["devtools"]["remote_debugging"]["allowed"] is True
        and chrome_data["os_crypt"]["encrypted_key"] == "secret-do-not-print"
        and chrome_data["unicode_note"] == "café",
    )
    check(
        "Chrome mode 0600 preserved",
        stat.S_IMODE(os.stat(chrome_ls).st_mode) == 0o600,
    )
    check(
        "Helium user-enabled is True",
        helium_data["devtools"]["remote_debugging"]["user-enabled"] is True,
    )
    check(
        "Helium mode 0640 preserved",
        stat.S_IMODE(os.stat(helium_ls).st_mode) == 0o640,
    )
    check(
        "Edge never-launched dir did not gain synthesized Local State",
        not os.path.exists(os.path.join(edge_dir, "Local State")),
    )

    # Second run is a silent no-op.
    before_bytes = open(chrome_ls, "rb").read()
    res2 = run_script(home)
    check("idempotent second run exits 0", res2.returncode == 0)
    check("idempotent second run prints nothing", res2.stdout == "" and res2.stderr == "")
    check("idempotent second run keeps exact bytes", open(chrome_ls, "rb").read() == before_bytes)


def test_running_skip_and_stale_lock_recovery(root):
    home = os.path.join(root, "locks")
    chrome_ls = seed_local_state(home, CHROME_REL, '{"browser":{}}')
    helium_ls = seed_local_state(home, HELIUM_REL, '{"browser":{}}')
    edge_ls = seed_local_state(home, EDGE_REL, '{"browser":{}}')

    # Chrome: live same-host SingletonLock (our own PID is guaranteed alive).
    os.symlink(
        f"{socket.gethostname()}-{os.getpid()}",
        os.path.join(home, CHROME_REL, "SingletonLock"),
    )

    # Helium: live SingletonSocket bound by a listening UNIX socket in a short /tmp path
    # (macOS AF_UNIX sun_path cap is 104 bytes).
    sock_dir = tempfile.mkdtemp(prefix="brd-s-", dir="/tmp")
    sock_path = os.path.join(sock_dir, "S")
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(1)
    os.symlink(sock_path, os.path.join(home, HELIUM_REL, "SingletonSocket"))

    # Edge: stale crashed-browser artifacts -- dead Socket + dead PID lock.
    dead_sock_path = os.path.join(sock_dir, "dead")
    dead_srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    dead_srv.bind(dead_sock_path)
    dead_srv.close()  # leaves socket inode on disk that refuses connections (ECONNREFUSED)
    os.symlink(dead_sock_path, os.path.join(home, EDGE_REL, "SingletonSocket"))
    # Spawn and reap a child so its PID is provably dead (or at least not holding anything).
    child = subprocess.Popen([sys.executable, "-c", "pass"])
    child.wait()
    # Pick a high non-existent PID to avoid immediate PID reuse flakiness.
    dead_pid = 999999
    while True:
        try:
            os.kill(dead_pid, 0)
            dead_pid -= 1
        except ProcessLookupError:
            break
        except PermissionError:
            dead_pid -= 1
    os.symlink(
        f"{socket.gethostname()}-{dead_pid}",
        os.path.join(home, EDGE_REL, "SingletonLock"),
    )

    try:
        res = run_script(home)
    finally:
        srv.close()
        try:
            os.unlink(sock_path)
            os.unlink(dead_sock_path)
            os.rmdir(sock_dir)
        except OSError:
            pass

    check("running-skip run exits 0", res.returncode == 0, res.stderr)
    check("Chrome skipped due to live SingletonLock", "Google Chrome: SKIP" in res.stdout, res.stdout)
    check("Helium skipped due to live SingletonSocket", "Helium: SKIP" in res.stdout, res.stdout)
    check("Chrome Local State untouched while running", open(chrome_ls).read() == '{"browser":{}}')
    check("Helium Local State untouched while running", open(helium_ls).read() == '{"browser":{}}')
    check(
        "Edge with stale socket+lock WAS updated",
        json.load(open(edge_ls))["devtools"]["remote_debugging"]["user-enabled"] is True,
    )


def test_failure_isolation_and_symlinks(root):
    home = os.path.join(root, "failures")
    # Chrome: malformed JSON containing a secret string that must not leak.
    bad_chrome = '{malformed json "super-secret-cookie-seed"'
    chrome_ls = seed_local_state(home, CHROME_REL, bad_chrome)
    # Helium: valid JSON, wrong shape for devtools (list instead of dict).
    bad_helium = '{"devtools":["wrong"]}'
    helium_ls = seed_local_state(home, HELIUM_REL, bad_helium)
    # Edge: Local State is a symlink to a real file outside the dir; must update target and stay a symlink.
    real_dir = os.path.join(root, "real-edge")
    os.makedirs(real_dir, exist_ok=True)
    real_edge = os.path.join(real_dir, "Local State.real")
    with open(real_edge, "w", encoding="utf-8") as fh:
        fh.write('{"edge_keep":true}')
    os.chmod(real_edge, 0o600)
    os.makedirs(os.path.join(home, EDGE_REL), exist_ok=True)
    edge_link = os.path.join(home, EDGE_REL, "Local State")
    os.symlink(real_edge, edge_link)

    res = run_script(home)
    check("partial failure exits 1", res.returncode == 1, f"rc={res.returncode}")
    check(
        "summary names both failed browsers",
        "2 of 3 browsers not configured: Google Chrome, Helium" in res.stderr,
        res.stderr,
    )
    check("malformed Local State secret not leaked", "super-secret-cookie-seed" not in res.stdout + res.stderr)
    check("Chrome malformed file byte-unchanged", open(chrome_ls).read() == bad_chrome)
    check("Helium wrong-shape file byte-unchanged", open(helium_ls).read() == bad_helium)
    check("Edge symlink stayed a symlink", os.path.islink(edge_link))
    check(
        "Edge symlink target gained user-enabled",
        json.load(open(real_edge))["devtools"]["remote_debugging"]["user-enabled"] is True
        and json.load(open(real_edge))["edge_keep"] is True,
    )


def main():
    with tempfile.TemporaryDirectory(prefix="browser-remote-debug-test-") as root:
        test_cli_contract(root)
        test_happy_idempotent_and_dry_run(root)
        test_running_skip_and_stale_lock_recovery(root)
        test_failure_isolation_and_symlinks(root)

    if FAILURES:
        print(f"\n{len(FAILURES)} probe(s) failed.", file=sys.stderr)
        return 1
    print("\nAll browser-remote-debug probes passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
