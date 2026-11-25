#!/usr/bin/env python3
"""Focused tests for scripts/sidepulse-led-demo.py launchctl and signal handling (#2081).

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
from unittest import mock

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
        self.timeouts = []

    def __call__(self, command, **kwargs):
        self.commands.append(list(command))
        self.timeouts.append(kwargs.get("timeout"))
        return subprocess.CompletedProcess(
            command, self.returncode, stdout="", stderr=self.stderr
        )


class TimeoutRun:
    """subprocess.run stand-in that hangs past its timeout (#2185)."""

    def __init__(self):
        self.commands = []
        self.timeouts = []

    def __call__(self, command, **kwargs):
        self.commands.append(list(command))
        self.timeouts.append(kwargs.get("timeout"))
        raise subprocess.TimeoutExpired(command, kwargs.get("timeout"))


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
    check("success: both calls bounded by the timeout",
          fake.timeouts == [demo.LAUNCHCTL_TIMEOUT_SECONDS] * 2, str(fake.timeouts))


def test_stop_timeout_is_surfaced():
    fake = TimeoutRun()
    err = io.StringIO()
    with mocked_run(fake), contextlib.redirect_stderr(err):
        result = demo.launchctl("stop")
    check("stop timeout: launchctl returns False", result is False)
    check("stop timeout: bootout attempted", fake.commands and "bootout" in fake.commands[0], str(fake.commands))
    check("stop timeout: finite timeout passed",
          fake.timeouts == [demo.LAUNCHCTL_TIMEOUT_SECONDS], str(fake.timeouts))
    check("stop timeout: timeout reported distinctly", "timed out" in err.getvalue(), err.getvalue())
    check("stop timeout: no fake exit status", "exit " not in err.getvalue(), err.getvalue())


def test_start_timeout_is_surfaced():
    fake = TimeoutRun()
    err = io.StringIO()
    with mocked_run(fake), contextlib.redirect_stderr(err):
        result = demo.launchctl("start")
    check("start timeout: launchctl returns False", result is False)
    check("start timeout: bootstrap attempted", fake.commands and "bootstrap" in fake.commands[0], str(fake.commands))
    check("start timeout: finite timeout passed",
          fake.timeouts == [demo.LAUNCHCTL_TIMEOUT_SECONDS], str(fake.timeouts))
    check("start timeout: timeout reported distinctly", "timed out" in err.getvalue(), err.getvalue())


def test_restart_timeout_is_reported_accurately():
    with tempfile.TemporaryDirectory() as d:
        target = Path(d)
        fake = TimeoutRun()
        out, err = io.StringIO(), io.StringIO()
        with mocked_run(fake), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            result = demo.restart_status_bar(target)
        check("restart timeout: returns False", result is False)
        check("restart timeout: does not claim restarted", "status bar restarted" not in out.getvalue(), out.getvalue())
        check("restart timeout: failure reported", "restart FAILED" in err.getvalue(), err.getvalue())
        check("restart timeout: timeout reported", "timed out" in err.getvalue(), err.getvalue())


def test_main_does_not_start_demo_when_stop_times_out():
    with tempfile.TemporaryDirectory() as d:
        target = Path(d)
        fake = TimeoutRun()
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
        check("main stop timeout: exits", raised is not None)
        check("main stop timeout: nothing written to LEDS.LED", not (target / "LEDS.LED").exists())
        check("main stop timeout: timeout surfaced", "timed out" in err.getvalue(), err.getvalue())


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


def test_double_restore_runs_one_bootstrap():
    """Ctrl-C invokes restore() twice (handler + finally); the second is a no-op (#2141)."""
    fake = FakeRun(0)
    handlers = {}
    argv, sys.argv = sys.argv, ["sidepulse-led-demo.py", "--device", "/unused", "--palette"]
    out, err = io.StringIO(), io.StringIO()
    try:
        with mocked_run(fake), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
             mock.patch.object(demo, "device_path", return_value=Path("/unused")), \
             mock.patch.object(demo, "write_program"), \
             mock.patch.object(demo, "run_palette", side_effect=KeyboardInterrupt), \
             mock.patch.object(demo.signal, "signal", side_effect=lambda sig, h: handlers.__setitem__(sig, h)):
            try:
                demo.main()
            except KeyboardInterrupt:
                pass
            try:
                handlers[demo.signal.SIGINT](demo.signal.SIGINT, None)
                exited = None
            except SystemExit as exc:
                exited = exc
    finally:
        sys.argv = argv
    bootstraps = [c for c in fake.commands if "bootstrap" in c]
    check("double restore: SIGINT handler exits 130", exited is not None and exited.code == 130,
          str(getattr(exited, "code", None)))
    check("double restore: exactly one bootstrap", len(bootstraps) == 1, str(fake.commands))
    check("double restore: no false restart failure", "restart FAILED" not in err.getvalue(), err.getvalue())


def test_sigterm_and_sighup_restore_once_and_exit_conventionally():
    for signum in (demo.signal.SIGTERM, demo.signal.SIGHUP):
        fake = FakeRun(0)
        handlers = {}
        argv, sys.argv = sys.argv, ["sidepulse-led-demo.py", "--device", "/unused", "--palette"]
        out, err = io.StringIO(), io.StringIO()
        try:
            with mocked_run(fake), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                 mock.patch.object(demo, "device_path", return_value=Path("/unused")), \
                 mock.patch.object(demo, "write_program"), \
                 mock.patch.object(
                     demo,
                     "run_palette",
                     side_effect=lambda *_args, **_kwargs: handlers[signum](signum, None),
                 ), \
                 mock.patch.object(
                     demo.signal,
                     "signal",
                     side_effect=lambda got, handler: handlers.__setitem__(got, handler),
                 ):
                try:
                    demo.main()
                    exited = None
                except SystemExit as exc:
                    exited = exc
        finally:
            sys.argv = argv
        bootstraps = [command for command in fake.commands if "bootstrap" in command]
        label = demo.signal.Signals(signum).name
        check(f"{label}: exits with 128 + signal", exited is not None and exited.code == 128 + signum,
              str(getattr(exited, "code", None)))
        check(f"{label}: exactly one bootstrap", len(bootstraps) == 1, str(fake.commands))
        check(f"{label}: no false restart failure", "restart FAILED" not in err.getvalue(), err.getvalue())


def test_normal_palette_completion_restores_once():
    fake = FakeRun(0)
    argv, sys.argv = sys.argv, ["sidepulse-led-demo.py", "--device", "/unused", "--palette"]
    try:
        with mocked_run(fake), contextlib.redirect_stdout(io.StringIO()), \
             mock.patch.object(demo, "device_path", return_value=Path("/unused")), \
             mock.patch.object(demo, "write_program"), \
             mock.patch.object(demo, "run_palette"), \
             mock.patch.object(demo.signal, "signal"):
            result = demo.main()
    finally:
        sys.argv = argv
    bootstraps = [command for command in fake.commands if "bootstrap" in command]
    check("normal completion: returns success", result == 0, str(result))
    check("normal completion: exactly one bootstrap", len(bootstraps) == 1, str(fake.commands))


test_stop_failure_is_surfaced()
test_successful_stop_and_start()
test_stop_timeout_is_surfaced()
test_start_timeout_is_surfaced()
test_restart_timeout_is_reported_accurately()
test_main_does_not_start_demo_when_stop_times_out()
test_restart_failure_is_reported_accurately()
test_restart_success()
test_main_does_not_start_demo_when_stop_fails()
test_double_restore_runs_one_bootstrap()
test_sigterm_and_sighup_restore_once_and_exit_conventionally()
test_normal_palette_completion_restores_once()

if FAILURES:
    print(f"\n{len(FAILURES)} check(s) failed")
    raise SystemExit(1)
print("\nall checks passed")
