"""Regression test for #1956: a failed hyprctl query must not read as picker gone."""
import importlib.util
import os
import pathlib
import subprocess
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "rd_picker_autogrant",
    pathlib.Path(__file__).with_name("rd-picker-autogrant.py"))
rpa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpa)

PICKER = {"pid": 42, "class": "hyprland-share-picker", "at": [0, 0],
          "size": [800, 600], "workspace": {"id": 1}}


class FailingQuery(unittest.TestCase):
    def setUp(self):
        self.logged = []
        patches = [
            mock.patch.object(rpa, "run", side_effect=OSError("hyprctl gone")),
            mock.patch.object(rpa, "calibrate", return_value=1.0),
            mock.patch.object(rpa, "active_ws", return_value=1),
            mock.patch.object(rpa, "click"),
            mock.patch.object(rpa, "goto_ws"),
            mock.patch.object(rpa.time, "sleep"),
            mock.patch.object(rpa, "log", side_effect=lambda *a: self.logged.append(" ".join(map(str, a)))),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def test_clients_failure_is_unknown_not_empty(self):
        self.assertIsNone(rpa.clients())
        self.assertIsNone(rpa.picker_gone(42))

    def test_grant_never_logs_ok_on_failed_query(self):
        self.assertIsNone(rpa.grant(PICKER))
        self.assertFalse(any("grant OK" in line for line in self.logged))
        self.assertTrue(any("grant UNKNOWN" in line for line in self.logged))


class ClosedPicker(unittest.TestCase):
    def test_grant_ok_when_query_succeeds_and_picker_gone(self):
        with mock.patch.object(rpa, "clients", return_value=[]), \
             mock.patch.object(rpa, "calibrate", return_value=1.0), \
             mock.patch.object(rpa, "active_ws", return_value=1), \
             mock.patch.object(rpa, "click"), \
             mock.patch.object(rpa, "goto_ws"), \
             mock.patch.object(rpa.time, "sleep"), \
             mock.patch.object(rpa, "log") as log:
            self.assertTrue(rpa.grant(PICKER))
            self.assertTrue(any("grant OK" in c.args[0] for c in log.call_args_list))


class StopLoop(Exception):
    pass


class MainLoopFetches(unittest.TestCase):
    """#2117 Bolt: one tick must cost exactly one clients() query.

    main() used to call clients() twice per tick (once to find pickers,
    once more to prune `handled`), i.e. two hyprctl spawns + JSON parses
    per 1.2s tick (~19ms each, measured on the laptop) for state one
    tick fresher. Pruning from the tick's own snapshot is equivalent
    (a pid that vanishes mid-tick drops one tick later; the 300s
    cooldown suppresses re-grants meanwhile), so the second fetch is
    pure overhead. This test drives three ticks and counts queries.
    """

    def test_one_clients_query_per_tick(self):
        calls = []

        def fake_clients():
            calls.append(1)
            return []

        sleeps = []

        def fake_sleep(_s):
            sleeps.append(1)
            if len(sleeps) >= 3:
                raise StopLoop

        with mock.patch.object(rpa, "rustdesk_connected", return_value=True), \
             mock.patch.object(rpa, "clients", side_effect=fake_clients), \
             mock.patch.object(rpa.time, "sleep", side_effect=fake_sleep), \
             mock.patch.object(rpa.os.path, "exists", return_value=False), \
             mock.patch.object(rpa, "log"):
            with self.assertRaises(StopLoop):
                rpa.main()
        self.assertEqual(len(sleeps), 3)
        self.assertEqual(len(calls), 3)


PICKER_WS2 = dict(PICKER, workspace={"id": 2})


def make_run(mode, calls):
    """A run() stub: hyprctl queries succeed; ydotool fails per mode.

    Modes: "calibrate" (every ydotool call exits 1), "move" (the
    calibration move succeeds, later mousemoves exit 1), "click"
    (mousemove ok, click exits 1), "timeout" (click raises
    TimeoutExpired), "key" (workspace-switch key exits 1), "ok".
    """
    moves = {"n": 0}

    def fake_run(cmd, timeout=10):
        calls.append(list(cmd))
        if cmd[0] == "hyprctl":
            if cmd[1] == "clients":
                return subprocess.CompletedProcess(cmd, 0, stdout="[]")
            if cmd[1] == "cursorpos":
                return subprocess.CompletedProcess(cmd, 0, stdout="100, 100")
            if cmd[1] == "activeworkspace":
                return subprocess.CompletedProcess(cmd, 0, stdout='{"id": 1}')
        if cmd[0] == "ydotool":
            sub = cmd[1]
            if mode == "calibrate":
                return subprocess.CompletedProcess(cmd, 1)
            if sub == "mousemove":
                moves["n"] += 1
                if mode == "move" and moves["n"] > 1:
                    return subprocess.CompletedProcess(cmd, 1)
            if sub == "click":
                if mode == "click":
                    return subprocess.CompletedProcess(cmd, 1)
                if mode == "timeout":
                    raise subprocess.TimeoutExpired(cmd, timeout)
            if sub == "key" and mode == "key":
                return subprocess.CompletedProcess(cmd, 1)
            return subprocess.CompletedProcess(cmd, 0)
        return subprocess.CompletedProcess(cmd, 0)

    return fake_run


class FailingYdotool(unittest.TestCase):
    """#2177: failed ydotool commands must not read as a successful grant."""

    def run_grant(self, mode, picker=PICKER):
        calls, logged = [], []
        with mock.patch.object(rpa, "run", side_effect=make_run(mode, calls)), \
             mock.patch.object(rpa.time, "sleep"), \
             mock.patch.object(rpa, "log",
                               side_effect=lambda *a: logged.append(" ".join(map(str, a)))):
            result = rpa.grant(picker)
        ydotool_calls = [c for c in calls if c[0] == "ydotool"]
        return result, ydotool_calls, logged

    def assert_no_grant_ok(self, logged):
        self.assertFalse(any("grant OK" in line for line in logged))

    def test_calibration_move_failure_aborts(self):
        result, ydotool_calls, logged = self.run_grant("calibrate")
        self.assertFalse(result)
        self.assert_no_grant_ok(logged)
        self.assertTrue(any("calibration" in line for line in logged))
        self.assertEqual(len(ydotool_calls), 1)

    def test_failed_mousemove_aborts_before_any_click(self):
        result, ydotool_calls, logged = self.run_grant("move")
        self.assertFalse(result)
        self.assert_no_grant_ok(logged)
        # calibration move + one failed move; no click, no second candidate
        self.assertEqual([c[1] for c in ydotool_calls],
                         ["mousemove", "mousemove"])

    def test_failed_click_aborts_after_first_attempt(self):
        result, ydotool_calls, logged = self.run_grant("click")
        self.assertFalse(result)
        self.assert_no_grant_ok(logged)
        self.assertEqual([c[1] for c in ydotool_calls].count("click"), 1)

    def test_click_timeout_aborts(self):
        result, ydotool_calls, logged = self.run_grant("timeout")
        self.assertFalse(result)
        self.assert_no_grant_ok(logged)
        self.assertEqual([c[1] for c in ydotool_calls].count("click"), 1)

    def test_failed_workspace_switch_aborts_before_clicking(self):
        result, ydotool_calls, logged = self.run_grant("key", PICKER_WS2)
        self.assertFalse(result)
        self.assert_no_grant_ok(logged)
        self.assertTrue(any("workspace switch" in line for line in logged))
        self.assertNotIn("click", [c[1] for c in ydotool_calls])

    def test_successful_grant_control(self):
        result, ydotool_calls, logged = self.run_grant("ok")
        self.assertTrue(result)
        self.assertTrue(any("grant OK" in line for line in logged))


class FailingCursorposMeasurement(unittest.TestCase):
    """#2297: a failed cursorpos measurement must not fall back to a
    guessed 2.45 scale. calibrate() returns None (scale unknown) and
    grant() aborts with zero click invocations."""

    def test_calibrate_none_when_cursorpos_fails(self):
        with mock.patch.object(rpa, "ydotool", return_value=True), \
             mock.patch.object(rpa, "cursorpos", return_value=None), \
             mock.patch.object(rpa.time, "sleep"):
            self.assertIsNone(rpa.calibrate())

    def test_calibrate_none_when_cursorpos_reads_zero(self):
        with mock.patch.object(rpa, "ydotool", return_value=True), \
             mock.patch.object(rpa, "cursorpos", return_value=(0, 100)), \
             mock.patch.object(rpa.time, "sleep"):
            self.assertIsNone(rpa.calibrate())

    def test_calibrate_measures_scale_control(self):
        with mock.patch.object(rpa, "ydotool", return_value=True), \
             mock.patch.object(rpa, "cursorpos", return_value=(245, 100)), \
             mock.patch.object(rpa.time, "sleep"):
            self.assertEqual(rpa.calibrate(), 2.45)

    def test_grant_aborts_with_zero_clicks_on_measurement_failure(self):
        ydotool_calls = []

        def fake_ydotool(*args):
            ydotool_calls.append(args)
            return True

        logged = []
        with mock.patch.object(rpa, "ydotool", side_effect=fake_ydotool), \
             mock.patch.object(rpa, "cursorpos", return_value=None), \
             mock.patch.object(rpa, "active_ws", return_value=1), \
             mock.patch.object(rpa.time, "sleep"), \
             mock.patch.object(rpa, "log",
                               side_effect=lambda *a: logged.append(" ".join(map(str, a)))):
            result = rpa.grant(PICKER)
        self.assertFalse(result)
        # Only the calibration probe move; no click, no candidate moves.
        self.assertEqual([c[0] for c in ydotool_calls], ["mousemove"])
        self.assertFalse(any("grant OK" in line for line in logged))
        self.assertTrue(any("calibration" in line for line in logged))


if __name__ == "__main__":
    unittest.main()
