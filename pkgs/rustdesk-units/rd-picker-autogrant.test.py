#!/usr/bin/env python3
"""Regression probe for rd-picker-autogrant grant() blind clicks (#2092).

grant() used to send real ydotool clicks at the picker's coordinates
even when it never switched to the picker's workspace: goto_ws()
silently no-oped for workspace ids outside 1..10, and grant() skipped
the switch entirely when active_ws() returned None.

This probe loads the real module with ydotool / run / active_ws
stubbed and asserts:
  * ws=15, cur=3, switch never confirmed -> grant() returns False and
    sends zero mousemove/click calls;
  * ws=5, cur=None (current workspace unknown) -> grant() returns
    False and sends zero mousemove/click calls;
  * positive control: picker already on the active workspace ->
    grant() proceeds, clicks, and returns True.

Run: python3 rd-picker-autogrant.test.py  (exit 0 = pass)
"""
import importlib.machinery
import importlib.util
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader(
    "rd_picker_autogrant", os.path.join(HERE, "rd-picker-autogrant.py"))
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

failures = []


def check(cond, msg):
    print(("ok: " if cond else "FAIL: ") + msg)
    if not cond:
        failures.append(msg)


def run_case(name, ws, active_seq, picker_gone_result=None):
    """Drive grant() with stubs; return (result, ydotool_calls)."""
    ydotool_calls = []
    def fake_ydotool(*args):
        ydotool_calls.append(args)
        return True

    mod.ydotool = fake_ydotool
    mod.run = lambda cmd, timeout=10: type("R", (), {"stdout": "", "returncode": 0})()
    seq = iter(active_seq)
    mod.active_ws = lambda: next(seq, active_seq[-1])
    mod.calibrate = lambda: 1.0
    if picker_gone_result is not None:
        mod.picker_gone = lambda pid: picker_gone_result
    picker = {"pid": 4242, "at": [100, 100], "size": [400, 300],
              "workspace": {"id": ws}}
    real_sleep = time.sleep
    time.sleep = lambda s: None
    try:
        result = mod.grant(picker)
    finally:
        time.sleep = real_sleep
    clicks = [c for c in ydotool_calls if c and c[0] in ("mousemove", "click")]
    return result, clicks, ydotool_calls


# Case 1: ws=15 is outside the digit-key range and the switch is never
# confirmed (active stays 3): no clicks, False.
result, clicks, _ = run_case("ws15-unconfirmed", 15, [3, 3])
check(result is False, "ws=15/cur=3 unconfirmed: grant returns False")
check(clicks == [], "ws=15/cur=3 unconfirmed: zero mousemove/click calls")

# Case 2: current workspace unknown: no clicks, False, and no ydotool
# calls at all (the guard fires before any switch attempt).
result, clicks, all_calls = run_case("cur-unknown", 5, [None])
check(result is False, "ws=5/cur=None: grant returns False")
check(clicks == [], "ws=5/cur=None: zero mousemove/click calls")
check(all_calls == [], "ws=5/cur=None: zero ydotool calls at all")

# Case 3 (positive control): picker already on the active workspace:
# grant proceeds to click and reports the picker's closure.
result, clicks, _ = run_case("already-there", 5, [5], picker_gone_result=True)
check(result is True, "ws=5/cur=5: grant returns True when picker closes")
check(len(clicks) > 0, "ws=5/cur=5: grant does click on the confirmed workspace")

if failures:
    print(f"{len(failures)} check(s) failed", file=sys.stderr)
    sys.exit(1)
print("all rd-picker-autogrant #2092 checks passed")
