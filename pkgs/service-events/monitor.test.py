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
- #1659: sockets() applies the same ASCII-decimal guard to lsof p-fields
  and skips malformed records without attributing their fields to the
  previous pid.

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

        # #1833: an append landing after the copy completes but before
        # truncation must survive in the rotated file, not vanish from
        # both files. Deterministic: wrap shutil.copyfile so the marker
        # is appended (O_APPEND, via "a") the instant the copy returns.
        raced = os.path.join(d, "raced.log")
        with open(raced, "w") as fh:
            fh.write(payload)
        marker = "CONCURRENT-APPEND\n"
        real_copyfile = _event.shutil.copyfile

        def copy_then_append(src, dst):
            real_copyfile(src, dst)
            with open(src, "a") as fh:
                fh.write(marker)

        _event.shutil.copyfile = copy_then_append
        try:
            rotated = _event.rotate(raced, 100, 3, copy_truncate=True)
        finally:
            _event.shutil.copyfile = real_copyfile
        check(
            "rotate raced append: returns archived size",
            rotated == len(payload) + len(marker),
            f"got {rotated}",
        )
        check("rotate raced append: original emptied", os.path.getsize(raced) == 0)
        with open(raced + ".1") as fh:
            check("rotate raced append: marker preserved in .1", fh.read() == payload + marker)

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

# #1659: malformed lsof p-fields are skipped without attaching their n/T
# records to the preceding valid pid; ordinary listener/connection parsing
# still round-trips, and a failed lsof run remains a failed sample (#1380).
monitor.run = lambda argv: (
    "p123\n"
    "n*:8000\nTST=LISTEN\n"
    "p²\n"
    "n*:9999\nTST=LISTEN\n"
    "p\n"
    "n*:7000\nTST=LISTEN\n"
    "p456\n"
    "n*:9000\nTST=LISTEN\n"
)
try:
    malformed_sockets = monitor.sockets({123, 456})
    raised = ""
except ValueError as exc:
    malformed_sockets, raised = None, str(exc)
check("1659 malformed lsof p-fields do not raise", malformed_sockets is not None, raised)
check(
    "1659 malformed records do not attach to preceding pid",
    malformed_sockets is not None
    and malformed_sockets[123] == ({"8000"}, set())
    and malformed_sockets[456] == ({"9000"}, set()),
    repr(malformed_sockets),
)

monitor.run = lambda argv: (
    "p123\n"
    "n*:3000\nTST=LISTEN\n"
    "n127.0.0.1:3000->127.0.0.1:51324\nTST=ESTABLISHED\n"
)
round_trip = monitor.sockets({123})
check(
    "1659 ordinary lsof listener and connection round-trip",
    round_trip == {
        123: (
            {"3000"},
            {"127.0.0.1:3000->127.0.0.1:51324"},
        )
    },
    repr(round_trip),
)

# #1728: every p record begins a new file record and resets its n-field.
# A T record without a current n-field is ignored, and must not prevent
# valid records after it from contributing to the same sample.
monitor.run = lambda argv: (
    "p123\n"
    "n*:8000\nTST=LISTEN\n"
    "p123\nTST=LISTEN\n"
    "p123\n"
    "n127.0.0.1:8000->127.0.0.1:51324\nTST=ESTABLISHED\n"
)
try:
    missing_listen_name = monitor.sockets({123})
    raised = ""
except Exception as exc:
    missing_listen_name, raised = None, f"{type(exc).__name__}: {exc}"
check("1728 missing-name LISTEN record does not raise", missing_listen_name is not None, raised)
check(
    "1728 missing-name LISTEN does not hide surrounding valid records",
    missing_listen_name == {
        123: (
            {"8000"},
            {"127.0.0.1:8000->127.0.0.1:51324"},
        )
    },
    repr(missing_listen_name),
)

monitor.run = lambda argv: (
    "p123\n"
    "n*:8000\nTST=LISTEN\n"
    "p123\n"
    "n127.0.0.1:8000->127.0.0.1:51324\nTST=ESTABLISHED\n"
    "p123\nTST=ESTABLISHED\n"
    "p123\n"
    "n*:9000\nTST=LISTEN\n"
)
try:
    missing_established_name = monitor.sockets({123})
    raised = ""
except Exception as exc:
    missing_established_name, raised = None, f"{type(exc).__name__}: {exc}"
check("1728 missing-name ESTABLISHED record does not raise", missing_established_name is not None, raised)
check(
    "1728 missing-name ESTABLISHED does not hide surrounding valid records",
    missing_established_name == {
        123: (
            {"8000", "9000"},
            {"127.0.0.1:8000->127.0.0.1:51324"},
        )
    },
    repr(missing_established_name),
)

monitor.run = lambda argv: None
check("1659 failed lsof sampler still returns None", monitor.sockets({123}) is None)


def _pid_reuse_probes():
    # #1985: a pid reused by a different watched role between ticks must
    # emit process.exit for the old (role, program) and process.start for
    # the new one, and the old role's connection state must be dropped
    # with the exit -- not carried into the new role, where its closing
    # would be logged as a conn.close under a role that never held it,
    # with the old connection's lived_s.
    import time as _time

    conn = "127.0.0.1:3000->127.0.0.1:51324"
    proc_samples = iter([
        {4242: ("opencode", 1, "opencode")},
        {4242: ("openchamber-server", 1, "openchamber")},
    ])
    sock_samples = iter([
        {4242: ({"3000"}, {conn})},
        {4242: ({"4000"}, set())},
    ])
    saved = (monitor.launchd_jobs, monitor.processes, monitor.sockets)
    monitor.launchd_jobs = lambda: {}
    monitor.processes = lambda: next(proc_samples)
    monitor.sockets = lambda pids: next(sock_samples)
    try:
        m = monitor.Monitor()
        events = []
        m.emit = lambda event, **fields: events.append((event, fields))
        m.last_rotate = _time.time()
        m.tick()
        for c in list(m.conns.get(4242, {})):
            m.conns[4242][c] = _time.time() - 100
        before = len(events)
        m.tick()
    finally:
        monitor.launchd_jobs, monitor.processes, monitor.sockets = saved
    tick2 = events[before:]
    check(
        "1985 pid reuse emits exit for old role",
        any(e == "process.exit" and f.get("role") == "opencode" and f.get("pid") == 4242 for e, f in tick2),
        repr(tick2),
    )
    check(
        "1985 pid reuse emits start for new role",
        any(e == "process.start" and f.get("role") == "openchamber-server" and f.get("pid") == 4242 for e, f in tick2),
        repr(tick2),
    )
    check(
        "1985 pid reuse drops old conns with old role",
        any(e == "conn.drop" and f.get("role") == "opencode" for e, f in tick2),
        repr(tick2),
    )
    check(
        "1985 no conn.close mis-attributed to new role",
        not any(e == "conn.close" for e, f in tick2),
        repr(tick2),
    )
    check(
        "1985 old conn state not carried into new role",
        conn not in m.conns.get(4242, {}),
        repr(m.conns),
    )


_rotate_probes()
_pid_reuse_probes()

print(f"\n{'ALL PASS' if not FAILURES else 'FAILURES: ' + ', '.join(FAILURES)}")
sys.exit(1 if FAILURES else 0)
