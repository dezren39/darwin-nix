#!/usr/bin/env python3
"""Unit probes for pkgs/service-events/monitor.py's samplers.

The package's other checks live in default.nix's install phase; this
file establishes the direct-import harness for the launchctl/ps
parsers: load the real monitor.py, stub its run() sampler, and drive
the parsing functions with crafted sampler output.

- #1613: launchd_jobs() gated int(pid) with a bare pid.isdigit() --
  str.isdigit() is also true for Unicode digit characters int()
  rejects (superscript/subscript digits, the class #935 fixed in
  event.py), so a superscript-digit pid field raised ValueError out
  of launchd_jobs() and aborted every monitor tick. processes() in
  the same file already guards with isascii() and isdigit().

Run: python3 monitor.test.py  (exit 0 = all probes passed)
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import monitor

FAILURES = []

# #1643: rotate(copy_truncate=True) must never truncate through a symlink.
# A symlinked log path is skipped (returns 0, warning on stderr, target
# byte-identical, no .1 written); a symlinked .1 slot is replaced, not
# written through; a normal oversized file still copy-truncate rotates.
import contextlib
import io
import tempfile

import event as _event


def _rotate_probes():
    with tempfile.TemporaryDirectory() as d:
        outside = os.path.join(d, "outside.log")
        payload = "x" * 260
        with open(outside, "w") as fh:
            fh.write(payload)
        link = os.path.join(d, "launchd.log")
        os.symlink(outside, link)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rotated = _event.rotate(link, 100, 3, copy_truncate=True)
        check("rotate symlinked log: returns 0", rotated == 0, f"got {rotated}")
        with open(outside) as fh:
            check("rotate symlinked log: target byte-identical", fh.read() == payload)
        check("rotate symlinked log: no .1 written", not os.path.exists(link + ".1"))
        check(
            "rotate symlinked log: skip named on stderr",
            "symlink" in err.getvalue() and link in err.getvalue(),
            err.getvalue(),
        )
        check("rotate symlinked log: link itself kept", os.path.islink(link))

        # Normal-file control: same call rotates as before.
        plain = os.path.join(d, "plain.log")
        with open(plain, "w") as fh:
            fh.write(payload)
        rotated = _event.rotate(plain, 100, 3, copy_truncate=True)
        check("rotate normal log: returns pre-rotation size", rotated == 260, f"got {rotated}")
        check("rotate normal log: original emptied", os.path.getsize(plain) == 0)
        with open(plain + ".1") as fh:
            check("rotate normal log: .1 holds old contents", fh.read() == payload)

        # Symlinked .1 slot: the slot link is replaced, its target untouched.
        plain2 = os.path.join(d, "plain2.log")
        with open(plain2, "w") as fh:
            fh.write(payload)
        slot_target = os.path.join(d, "slot-target.log")
        with open(slot_target, "w") as fh:
            fh.write("keep me")
        os.symlink(slot_target, plain2 + ".1")
        rotated = _event.rotate(plain2, 100, 3, copy_truncate=True)
        check("rotate symlinked .1 slot: rotates", rotated == 260, f"got {rotated}")
        with open(slot_target) as fh:
            check("rotate symlinked .1 slot: target untouched", fh.read() == "keep me")
        check("rotate symlinked .1 slot: slot is a regular file", not os.path.islink(plain2 + ".1"))
        with open(plain2 + ".1") as fh:
            check("rotate symlinked .1 slot: .1 holds old contents", fh.read() == payload)




def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'}: {name}" + (f" -- {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


HEADER = "PID\tStatus\tLabel\n"

# #1613: a superscript-digit pid field is "no pid" (None), never a
# ValueError -- and the rest of the sample still parses: an ordinary
# decimal pid converts, and '-' (not running) stays None, including
# for a label matched by prefix.
monitor.run = lambda argv: (
    HEADER
    + "\u00b2\t0\torg.nixos.openchamber\n"
    + "123\t0\torg.nixos.mcpx\n"
    + "-\t1\tapplication.dev.openchamber.desktop.42\n"
    + "999\t0\tcom.example.unwatched\n"
)
try:
    jobs = monitor.launchd_jobs()
    raised = ""
except ValueError as exc:
    jobs, raised = None, str(exc)
check("1613 unicode-digit pid does not raise", jobs is not None, raised)
check("1613 unicode-digit pid reads as no pid",
      jobs is not None and jobs.get("org.nixos.openchamber") == (None, "0"), repr(jobs))
check("1613 ordinary pid still converts",
      jobs is not None and jobs.get("org.nixos.mcpx") == (123, "0"), repr(jobs))
check("1613 dash pid stays None for prefix label",
      jobs is not None and jobs.get("application.dev.openchamber.desktop.42") == (None, "1"), repr(jobs))
check("1613 unwatched label still skipped",
      jobs is not None and "com.example.unwatched" not in jobs, repr(jobs))

# A failed sampler (run() -> None) still reads as a failed sample
# (#1380), not as an empty job set.
monitor.run = lambda argv: None
check("1613 failed sampler still returns None", monitor.launchd_jobs() is None)

_rotate_probes()

print(f"\n{'ALL PASS' if not FAILURES else 'FAILURES: ' + ', '.join(FAILURES)}")
sys.exit(1 if FAILURES else 0)
