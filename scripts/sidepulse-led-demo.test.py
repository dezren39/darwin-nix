#!/usr/bin/env python3
import importlib.util, io, sys, types
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch

compose = types.ModuleType("sidepulse.compose")
for name in "TIER_DEMAND SIGNALS SIGNAL_COLORS MULTI_SIGNAL_MODES MULTI_SIGNAL_PRIORITY SIGNAL_ASK SIGNAL_BUSY SIGNAL_DONE SIGNAL_ERROR MultiSignalTiming arrival_queue compose_program mode_is_dynamic".split():
    setattr(compose, name, {} if name in {"SIGNALS", "SIGNAL_COLORS"} else name)
compose.MULTI_SIGNAL_MODES = ()
sys.modules["sidepulse"] = types.ModuleType("sidepulse")
sys.modules["sidepulse.compose"] = compose
spec = importlib.util.spec_from_file_location("demo", Path(__file__).with_name("sidepulse-led-demo.py"))
demo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(demo)

error = io.StringIO()
with patch.object(sys, "argv", ["demo", "--device", "/unused"]), \
     patch.object(demo, "device_path", return_value=Path("/unused")), \
     patch.object(demo.subprocess, "run", return_value=types.SimpleNamespace(returncode=5, stderr=b"service not found")), \
     patch.object(demo, "write_program") as write, redirect_stderr(error):
    assert demo.main() == 1
assert not write.called
assert "demo not started: service not found" in error.getvalue()

handlers = {}
ok = types.SimpleNamespace(returncode=0, stderr=b"")
out = io.StringIO()
err = io.StringIO()
with patch.object(sys, "argv", ["demo", "--device", "/unused", "--palette"]), \
     patch.object(demo, "device_path", return_value=Path("/unused")), \
     patch.object(demo.subprocess, "run", return_value=ok) as run, \
     patch.object(demo, "write_program"), \
     patch.object(demo, "run_palette", side_effect=KeyboardInterrupt), \
     patch.object(demo.signal, "signal", side_effect=lambda sig, h: handlers.__setitem__("sigint", h)), \
     redirect_stderr(err):
    try:
        demo.main()
    except KeyboardInterrupt:
        pass
    try:
        handlers["sigint"](None, None)
    except SystemExit as exit_:
        assert exit_.code == 130
bootstraps = [c for c in run.call_args_list if "bootstrap" in c.args[0]]
assert len(bootstraps) == 1, bootstraps
assert "was not handed back" not in err.getvalue() + out.getvalue()
print("sidepulse-led-demo: stop failure prevents writes and explains why")
print("sidepulse-led-demo: double restore runs one bootstrap with no false failure")
