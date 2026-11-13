#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Enable remote debugging in Chromium-family Local State files at activation.

Since Chrome 136, Chromium-family browsers ignore --remote-debugging-port on
their default user-data-dir and gate CDP on the persistent in-browser toggle at
chrome://inspect/#remote-debugging (edge://inspect/#remote-debugging). That
toggle writes one boolean into the browser's root Local State JSON file:

    devtools.remote_debugging.user-enabled = true

When set, every normal launch (Dock, Spotlight, open -a, URL click) opens the
approval-gated CDP server on 127.0.0.1:9222 and writes DevToolsActivePort in the
user-data-dir, while keeping navigator.webdriver false and prompting the user
in-browser to allow an incoming connection.

Safety invariants (mirroring mcp-clients.py's #906/#1133/#1205/#1562 discipline):
- Only browsers whose user-data-dir already exists are checked; uninstalled or
  never-launched browsers are skipped cleanly.
- If a browser is currently running (live SingletonSocket, live same-host
  SingletonLock PID, or open file under user-data-dir), its Local State is NOT
  written -- Chromium overwrites Local State from memory on shutdown and would
  clobber or race the edit. A running browser is reported as SKIP at exit 0.
- Only devtools.remote_debugging.user-enabled is set; every other key and the
  file's mode are preserved, written atomically via temp+rename in the resolved
  target's directory (preserving symlinks if Local State is linked).
- File contents are never printed, logged, or backed up outside the browser's
  own directory (Local State holds personal/account metadata).
- Each browser is handled independently: a malformed Local State or non-dict
  intermediate value is reported on stderr without touching the file, the
  remaining browsers still run, and the process exits 1 naming the failed
  browsers so browser-remote-debug-activation.sh can record a service-event.
"""

import errno
import json
import os
import shutil
import socket
import sys

HOME = os.path.expanduser("~")
DRY_RUN = "--dry-run" in sys.argv
USAGE = "usage: browser-remote-debug.py [--dry-run] [--help]"

# Every Chromium-family cask declared in casks.nix:
#   google-chrome   -> ~/Library/Application Support/Google/Chrome
#   helium-browser  -> ~/Library/Application Support/net.imput.helium
#   microsoft-edge  -> ~/Library/Application Support/Microsoft Edge
BROWSERS = [
    ("Google Chrome", "Library/Application Support/Google/Chrome"),
    ("Helium", "Library/Application Support/net.imput.helium"),
    ("Microsoft Edge", "Library/Application Support/Microsoft Edge"),
]


def unknown_argument(args):
    """Return the first argument other than a single optional --dry-run."""
    if args in ([], ["--dry-run"]):
        return None
    for arg in args:
        if arg != "--dry-run":
            return arg
    return args[1]


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def browser_running_reason(user_data_dir):
    """Return a short reason string if a Chromium instance holds user_data_dir, else None.

    Checks both Chromium's SingletonSocket (authoritative UNIX domain socket
    bound by a live browser process) and SingletonLock (<hostname>-<pid>
    symlink). A crashed browser can leave stale symlinks behind: a socket
    whose connect raises ECONNREFUSED/ENOENT and a lock whose same-host PID
    no longer exists are stale, not running. A foreign-host lock is treated
    conservatively as running.
    """
    sock_link = os.path.join(user_data_dir, "SingletonSocket")
    if os.path.islink(sock_link):
        try:
            target = os.readlink(sock_link)
            if not os.path.isabs(target):
                target = os.path.normpath(os.path.join(user_data_dir, target))
        except OSError as exc:
            return f"unreadable SingletonSocket ({exc})"
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(0.2)
        try:
            sock.connect(target)
            return "SingletonSocket accepting connections"
        except OSError as exc:
            if exc.errno not in (
                errno.ECONNREFUSED,
                errno.ENOENT,
                errno.ENOTSOCK,
            ):
                return f"SingletonSocket busy ({exc})"
        finally:
            sock.close()

    lock_link = os.path.join(user_data_dir, "SingletonLock")
    if os.path.islink(lock_link):
        try:
            target = os.readlink(lock_link)
        except OSError as exc:
            return f"unreadable SingletonLock ({exc})"
        if "-" not in target:
            return f"unrecognized SingletonLock target ({target!r})"
        host, pid_str = target.rsplit("-", 1)
        local_hosts = {
            socket.gethostname(),
            socket.getfqdn(),
            socket.gethostname().split(".")[0],
        }
        if host not in local_hosts:
            return f"SingletonLock held by host {host}"
        if not pid_str.isascii() or not pid_str.isdigit():
            return f"unrecognized SingletonLock pid ({pid_str!r})"
        pid = int(pid_str)
        if pid > 0 and _pid_alive(pid):
            return f"SingletonLock held by live pid {pid}"

    return None


def ensure_browser(name, user_data_dir):
    """Ensure devtools.remote_debugging.user-enabled is true in user_data_dir/Local State."""
    if not os.path.lexists(user_data_dir):
        return
    if not os.path.isdir(user_data_dir):
        raise ValueError("user-data-dir is not a directory; not changed")

    local_state = os.path.join(user_data_dir, "Local State")
    if not os.path.lexists(local_state):
        # Never-launched profile dir: do not synthesize a minimal Local State
        # before the browser's own first-run initialization has populated it.
        return

    running = browser_running_reason(user_data_dir)
    if running is not None:
        print(
            f"browser-remote-debug: {name}: SKIP (browser is running: {running}; Local State left untouched)"
        )
        return

    with open(local_state, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(
            f"Local State top-level value is a {type(data).__name__}, not an object; not changed"
        )

    devtools = data.get("devtools")
    if devtools is not None and not isinstance(devtools, dict):
        raise ValueError(
            f"Local State devtools is a {type(devtools).__name__}, not an object; not changed"
        )
    remote_debugging = (devtools or {}).get("remote_debugging")
    if remote_debugging is not None and not isinstance(remote_debugging, dict):
        raise ValueError(
            f"Local State devtools.remote_debugging is a {type(remote_debugging).__name__}, not an object; not changed"
        )

    if (remote_debugging or {}).get("user-enabled") is True:
        return

    print(
        f"browser-remote-debug: {name} ({local_state}): devtools.remote_debugging.user-enabled = true"
        f"{' (dry run)' if DRY_RUN else ''}"
    )
    if DRY_RUN:
        return

    devtools_obj = dict(devtools) if isinstance(devtools, dict) else {}
    remote_obj = dict(remote_debugging) if isinstance(remote_debugging, dict) else {}
    remote_obj["user-enabled"] = True
    devtools_obj["remote_debugging"] = remote_obj
    data["devtools"] = devtools_obj

    dest = os.path.realpath(local_state) if os.path.islink(local_state) else local_state
    dest_dir = os.path.dirname(dest)
    tmp = os.path.join(dest_dir, f".{os.path.basename(dest)}.browser-remote-debug.tmp")
    encoded = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(encoded)
        shutil.copymode(dest, tmp)
        os.replace(tmp, dest)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main():
    if sys.argv[1:] in (["--help"], ["-h"]):
        print(USAGE)
        print(
            "Enable devtools.remote_debugging.user-enabled in Chromium-family Local State"
        )
        print(
            "files when the browser is not running; --dry-run reports instead of writing."
        )
        return 0
    bad = unknown_argument(sys.argv[1:])
    if bad is not None:
        print(f"browser-remote-debug: unknown argument: {bad}", file=sys.stderr)
        print(USAGE, file=sys.stderr)
        return 2

    failed = []
    for name, rel_dir in BROWSERS:
        user_data_dir = os.path.join(HOME, rel_dir)
        try:
            ensure_browser(name, user_data_dir)
        except Exception as exc:
            failed.append(name)
            print(
                f"browser-remote-debug: {name} ({user_data_dir}): FAILED: {exc}",
                file=sys.stderr,
            )
    if failed:
        print(
            f"browser-remote-debug: {len(failed)} of {len(BROWSERS)} browsers not configured: {', '.join(failed)}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
