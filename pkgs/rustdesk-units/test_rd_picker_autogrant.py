"""Regression test for #1956: a failed hyprctl query must not read as picker gone."""
import importlib.util
import os
import pathlib
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


if __name__ == "__main__":
    unittest.main()
