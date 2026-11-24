#!/usr/bin/env python3
"""Regression probes for workspace safety in rd-picker-autogrant."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).with_name("rd-picker-autogrant.py")
SPEC = importlib.util.spec_from_file_location("rd_picker_autogrant", MODULE_PATH)
AUTOGRANT = importlib.util.module_from_spec(SPEC)
with patch("os.makedirs"):
    SPEC.loader.exec_module(AUTOGRANT)


class GrantWorkspaceSafetyTests(unittest.TestCase):
    def setUp(self):
        self.ydotool_calls = []
        self.picker = {"pid": 123, "at": [10, 20], "size": [400, 300],
                       "workspace": {"id": 15}}

    def run_grant(self, current_workspace):
        with patch.object(AUTOGRANT, "active_ws", return_value=current_workspace), \
             patch.object(AUTOGRANT, "ydotool", side_effect=lambda *args: self.ydotool_calls.append(args)), \
             patch.object(AUTOGRANT, "log"):
            return AUTOGRANT.grant(self.picker)

    def test_workspace_15_is_refused_without_mouse_input(self):
        self.assertFalse(self.run_grant(3))
        self.assertEqual(self.ydotool_calls, [])

    def test_unknown_current_workspace_is_refused_without_mouse_input(self):
        self.picker["workspace"]["id"] = 5
        self.assertFalse(self.run_grant(None))
        self.assertEqual(self.ydotool_calls, [])

    def test_unknown_picker_workspace_is_refused_without_mouse_input(self):
        self.picker["workspace"]["id"] = None
        self.assertFalse(self.run_grant(3))
        self.assertEqual(self.ydotool_calls, [])

    def test_unverified_switch_is_refused_before_mouse_input(self):
        self.picker["workspace"]["id"] = 5
        workspace_reads = iter((3, 4))
        with patch.object(AUTOGRANT, "active_ws", side_effect=lambda: next(workspace_reads)), \
             patch.object(AUTOGRANT, "ydotool", side_effect=lambda *args: self.ydotool_calls.append(args)), \
             patch.object(AUTOGRANT, "log"):
            self.assertFalse(AUTOGRANT.grant(self.picker))
        self.assertFalse(any(call[0] in ("mousemove", "click") for call in self.ydotool_calls))


if __name__ == "__main__":
    unittest.main()
