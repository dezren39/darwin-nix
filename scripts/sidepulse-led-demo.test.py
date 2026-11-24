#!/usr/bin/env python3
"""Focused tests for scripts/sidepulse-led-demo.py launchctl handling (#2026).

The demo script imports sidepulse.compose, which lives in the external
sidepulse source, so this harness stubs that module before loading the
real script by path, then drives launchctl()/restart_status_bar()/main()
with mocked subprocess.run outcomes. Hardware-free and deterministic.

Run: python3 scripts/sidepulse-led-demo.test.py  (exit 0 = all passed)
"""

import contextlib
import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import types
from pathlib import Path

HERE = Path(os.path.dirname(os.path.abspath(__file__)))


def _stub_compose() -> None:
    pkg = types.ModuleType("sidepulse")
    compose = types.ModuleType("sidepulse.compose")
    compose.TIER_DEMAND = "demand"
    compose.SIGNALS = {}
    compose.SIGNAL_COLORS = {}
    compose.MULTI_SIGNAL_MODES = ()
    compose.MULTI_SIGNAL_PRIORITY = "priority"
    compose.SIGNAL_ASK = "ask"
    compose.SIGNAL_BUSY = "busy"
    compose.SIGNAL_DONE = "done"
    compose.SIGNAL_ERROR = "error"
    compose.MultiSignalTiming = object
    compose.arrival_queue = lambda *a, **k: ()
    compose.compose_program = None
    compose.mode_is_dynamic = lambda mode: False
    pkg.compose = compose
    sys.modules.setdefault("sidepulse", pkg)
    sys.modules["sidepulse.compose"] = compose


_stub_compose()
_spec = importlib.util.spec_from_file_location(
    "sidepulse_led_demo", HERE / "sidepulse-led-demo.py"
)
demo = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(demo)

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print(f"ok   {name}")
    else:
        FAILURES.append(name)
        print(f"FAIL {name}  {detail}")


class FakeRun:
    """subprocess.run stand-in returning a fixed exit code/stderr."""

    def __init__(self, returncode, stderr=""):
        self.returncode = returncode
        self.stderr = stderr
        self.commands = []

    def __call__(self, command, **kwargs):
        self.commands.append(list(command))
        return subprocess.CompletedProcess(
            command, self.returncode, stdout="", stderr=self.stderr
        )


@contextlib.contextmanager
def mocked_run(fake):
    original = subprocess.run
    subprocess.run = fake
    try:
        yield fake
    finally:
        subprocess.run = original


def test_stop_failure_is_surfaced():
    fake = FakeRun(5, "launchctl: service not found")
    err = io.StringIO()
    with mocked_run(fake), contextlib.redirect_stderr(err):
        result = demo.launchctl("stop")
    check("stop failure: launchctl returns False", result is False)
    check("stop failure: bootout attempted", fake.commands and "bootout" in fake.commands[0], str(fake.commands))
    check("stop failure: exit surfaced", "exit 5" in err.getvalue(), err.getvalue())
    check("stop failure: stderr surfaced", "service not found" in err.getvalue(), err.getvalue())


def test_successful_stop_and_start():
    fake = FakeRun(0)
    with mocked_run(fake):
        stopped = demo.launchctl("stop")
        started = demo.launchctl("start")
    check("success: stop returns True", stopped is True)
    check("success: start returns True", started is True)
    check("success: bootstrap attempted", len(fake.commands) == 2 and "bootstrap" in fake.commands[1], str(fake.commands))


def test_restart_failure_is_reported_accurately():
    with tempfile.TemporaryDirectory() as d:
        target = Path(d)
        fake = FakeRun(5, "launchctl: bootstrap failed")
        out, err = io.StringIO(), io.StringIO()
        with mocked_run(fake), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            result = demo.restart_status_bar(target)
        check("restart failure: returns False", result is False)
        check("restart failure: does not claim restarted", "status bar restarted" not in out.getvalue(), out.getvalue())
        check("restart failure: failure reported", "restart FAILED" in err.getvalue(), err.getvalue())


def test_restart_success():
    with tempfile.TemporaryDirectory() as d:
        target = Path(d)
        fake = FakeRun(0)
        out = io.StringIO()
        with mocked_run(fake), contextlib.redirect_stdout(out):
            result = demo.restart_status_bar(target)
        check("restart success: returns True", result is True)
        check("restart success: restarted reported", "status bar restarted" in out.getvalue(), out.getvalue())


def test_main_does_not_start_demo_when_stop_fails():
    with tempfile.TemporaryDirectory() as d:
        target = Path(d)
        fake = FakeRun(5, "launchctl: service not found")
        argv, sys.argv = sys.argv, ["sidepulse-led-demo.py", "--device", str(target)]
        err = io.StringIO()
        try:
            with mocked_run(fake), contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                try:
                    demo.main()
                    raised = None
                except SystemExit as exc:
                    raised = exc
        finally:
            sys.argv = argv
        check("main stop failure: exits", raised is not None)
        check("main stop failure: nothing written to LEDS.LED", not (target / "LEDS.LED").exists())
        check("main stop failure: failure surfaced", "exit 5" in err.getvalue(), err.getvalue())


def test_restore_runs_once_on_repeated_invocation():
    from unittest.mock import patch

    handlers = {}
    fake = FakeRun(0)
    argv = sys.argv
    sys.argv = ["demo", "--device", "/unused", "--palette"]
    try:
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            with mocked_run(fake), \
                 contextlib.redirect_stderr(io.StringIO()), \
                 contextlib.redirect_stdout(io.StringIO()), \
                 patch.object(demo, "device_path", return_value=target), \
                 patch.object(demo, "run_palette", side_effect=KeyboardInterrupt), \
                 patch.object(demo.signal, "signal", side_effect=lambda sig, h: handlers.__setitem__("sigint", h)):
                try:
                    demo.main()
                except KeyboardInterrupt:
                    pass
                try:
                    handlers["sigint"](None, None)
                except SystemExit:
                    pass
    finally:
        sys.argv = argv
    bootstraps = [c for c in fake.commands if "bootstrap" in c]
    check("restore once: one launchctl start/bootstrap", len(bootstraps) == 1, str(fake.commands))


test_stop_failure_is_surfaced()
test_successful_stop_and_start()
test_restore_runs_once_on_repeated_invocation()
test_restart_failure_is_reported_accurately()
test_restart_success()
test_main_does_not_start_demo_when_stop_fails()

if FAILURES:
    print(f"\n{len(FAILURES)} check(s) failed")
    raise SystemExit(1)
print("\nall checks passed")
