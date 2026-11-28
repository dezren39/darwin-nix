#!/usr/bin/env python3
"""rd-picker-autogrant: auto-grant the Hyprland share picker for RustDesk.

Why this exists (root cause, found 2026-11-08, code#5509): the laptop's
xdg-desktop-portal-hyprland (1.4.1) has NO restore-token / persisted-grant
support, and its share picker's "Remember this choice" does not persist
across requests (verified empirically: three consecutive portal flows each
spawned a fresh picker). So EVERY RustDesk Wayland session blocks on a
human clicking the picker at the laptop. The picker opens on a workspace
that may not be visible, RustDesk's client retries CreateSession while the
first SelectSources is still pending, xdph does not answer the second
CreateSession, and the client dies with "xdp-portal-unavailable". This
watcher performs the grant a local human would, scoped tightly:

  * only while a RustDesk client connection is established on :21118
    (ss shows an established TCP connection involving port 21118), and
  * only for windows whose class is hyprland-share-picker, and
  * kill switch: if ~/.config/rd-autogrant.DISABLED exists, do nothing.

It switches to the picker's workspace if needed, clicks the monitor row
and the Share button with ydotool (calibrating ydotool's absolute-move
scale against hyprctl cursorpos each grant), then switches back.
"""
import json, os, subprocess, sys, time

UID = os.getuid()
RT = f"/run/user/{UID}"
ENV = dict(os.environ,
           XDG_RUNTIME_DIR=RT,
           WAYLAND_DISPLAY=os.environ.get("WAYLAND_DISPLAY", "wayland-1"))
LOG = os.path.expanduser("~/.local/share/logs/rd-autogrant.log")
DISABLE = os.path.expanduser("~/.config/rd-autogrant.DISABLED")
os.makedirs(os.path.dirname(LOG), exist_ok=True)

def log(*a):
    line = time.strftime("%Y-%m-%d %H:%M:%S") + " " + " ".join(str(x) for x in a)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass
    print(line, flush=True)

def his():
    """Hyprland instance signature (newest dir under $XDG_RUNTIME_DIR/hypr)."""
    base = os.path.join(RT, "hypr")
    try:
        return max((os.path.join(base, d) for d in os.listdir(base)),
                   key=os.path.getmtime).split("/")[-1]
    except Exception:
        return ""

def run(cmd, timeout=10):
    e = dict(ENV, HYPRLAND_INSTANCE_SIGNATURE=his())
    return subprocess.run(cmd, capture_output=True, text=True,
                          timeout=timeout, env=e)

def clients():
    """Client list, or None when the query fails (unknown, not empty)."""
    try:
        out = run(["hyprctl", "clients", "-j"]).stdout
        return json.loads(out)
    except Exception:
        return None

def active_ws():
    try:
        out = run(["hyprctl", "activeworkspace", "-j"]).stdout
        return json.loads(out).get("id")
    except Exception:
        return None

def cursorpos():
    try:
        out = run(["hyprctl", "cursorpos"]).stdout
        x, y = out.strip().split(",")
        return int(x), int(y)
    except Exception:
        return None

def ydotool(*args):
    """Run one ydotool command; True only when it exits 0.

    A nonzero exit, a timeout, or a spawn failure (e.g. the ydotool
    device is unavailable) all mean the input was NOT injected (#2177):
    callers must see that instead of the old fire-and-forget behaviour,
    where a failed command read the same as a successful one.
    """
    try:
        return run(["ydotool"] + list(args), timeout=8).returncode == 0
    except Exception:
        return False

def calibrate():
    """ydotool absolute moves are scaled (observed x2.45). Measure it.

    Returns None whenever the scale was not actually measured: the
    calibration move itself failed (the probe move was never injected),
    or cursorpos() failed afterwards (hyprctl timeout/spawn/parse
    failure -- the probe move landed but its result is unknown), or
    cursorpos() read x=0 after a probe move to x=100 (a 0 reading cannot
    be the observed result of that move, so the measurement failed; x=0
    is a legal cursor column, not evidence for any particular scale).
    In every one of those cases the scale is unknown and every later
    click would be a guess, so no guessed scale (e.g. the old silent
    2.45 fallback, #2297) is ever returned.
    """
    if not ydotool("mousemove", "--absolute", "-x", "100", "-y", "100"):
        return None
    time.sleep(0.6)
    pos = cursorpos()
    if not pos or pos[0] == 0:
        return None
    return pos[0] / 100.0

def click(x, y, scale):
    """Move + click; False on the first failed input operation."""
    if not ydotool("mousemove", "--absolute", "-x", str(round(x / scale)),
                   "-y", str(round(y / scale))):
        return False
    time.sleep(0.7)
    if not ydotool("click", "0xC0"):
        return False
    time.sleep(0.7)
    return True

# evdev codes: SUPER_L=125; digit keys '1'..'9' = 2..10, '0' = 11
def goto_ws(n):
    """Switch to workspace n; return True iff the switch was issued.

    The digit-key chord only covers workspaces 1..10, but Hyprland ids
    have no 10-cap: beyond that range use hyprctl dispatch instead of
    silently doing nothing (the caller confirms via active_ws()).
    """
    if n is None or n < 1:
        log(f"goto_ws: refusing invalid workspace {n!r}")
        return False
    if n <= 10:
        code = n + 1 if n < 10 else 11
        ok = ydotool("key", "125:1", f"{code}:1", f"{code}:0", "125:0")
    else:
        try:
            ok = run(["hyprctl", "dispatch", "workspace", str(n)]).returncode == 0
        except Exception as e:
            log(f"goto_ws: hyprctl dispatch to workspace {n} failed: {e!r}")
            return False
    time.sleep(0.9)
    return ok

def rustdesk_connected():
    try:
        out = subprocess.run(["ss", "-tn", "state", "established"],
                             capture_output=True, text=True, timeout=8).stdout
        return ":21118" in out
    except Exception:
        return False

def picker_gone(pid):
    """True/False, or None when the client query failed (unknown)."""
    cl = clients()
    if cl is None:
        return None
    return all(c.get("pid") != pid for c in cl
               if c.get("class") == "hyprland-share-picker")

def grant(picker):
    pid = picker.get("pid")
    x, y = picker["at"]; w, h = picker["size"]
    ws = picker.get("workspace", {}).get("id")
    log(f"picker pid={pid} rect=({x},{y},{w}x{h}) ws={ws} - granting")
    # Never click blind (#2092): the click coordinates only make sense
    # on the picker's workspace, so both workspaces must be known and
    # any needed switch must be CONFIRMED before the first click --
    # calibrate() included, since it too sends a mousemove. Aborting
    # here sends zero clicks.
    if ws is None:
        log("grant ABORT - picker workspace unknown; not clicking")
        return False
    cur = active_ws()
    if cur is None:
        log("grant ABORT - current workspace unknown; not clicking")
        return False
    switched = False
    if ws != cur:
        if not goto_ws(ws):
            log(f"grant FAILED - workspace switch to {ws} failed; not clicking")
            return False
        switched = True
        now = active_ws()
        if now != ws:
            log(f"grant ABORT - switch to workspace {ws} not confirmed (active={now}); not clicking")
            return False
    scale = calibrate()
    if scale is None:
        log("grant FAILED - ydotool calibration failed (move or cursorpos measurement); aborting")
        return False
    log(f"ydotool scale={scale:.3f}")
    gone = None
    input_failed = False
    # candidate (row_rel_y, share_rel_x_from_right) pairs; first that closes wins
    for row_rel, share_off in ((150, 48), (130, 107), (170, 48)):
        if not click(x + w // 2, y + row_rel, scale) or \
           not click(x + w - share_off, y + h - 30, scale):
            # #2177: a failed input operation aborts the attempt. The
            # picker disappearing on its own afterwards must not turn
            # clicks that never landed into a "grant OK".
            input_failed = True
            break
        time.sleep(1.6)
        gone = picker_gone(pid)
        if gone:
            log(f"grant OK (row_rel={row_rel} share_off={share_off})")
            break
    else:
        if gone is None:
            log("grant UNKNOWN - hyprctl clients query failed; will retry")
        else:
            log("grant FAILED - picker still open after all attempts")
    if input_failed:
        log("grant FAILED - ydotool input command failed; aborting")
        gone = False
    if switched and not goto_ws(cur):
        log("grant WARN - ydotool switch back to workspace failed")
    return gone

def main():
    log("rd-picker-autogrant started")
    handled = {}  # pid -> timestamp of grant attempt
    while True:
        try:
            if not os.path.exists(DISABLE) and rustdesk_connected():
                cl = clients()
                for c in cl or []:
                    if c.get("class") != "hyprland-share-picker":
                        continue
                    pid = c.get("pid")
                    if pid in handled and time.time() - handled[pid] < 300:
                        continue
                    handled[pid] = time.time()
                    if grant(c) is None:
                        handled.pop(pid, None)
                live_now = cl
                if live_now is not None:
                    # Prune from this tick's own snapshot instead of a
                    # second clients() query: the extra fetch cost a full
                    # hyprctl spawn + JSON parse per 1.2s tick (~19ms
                    # measured on the laptop) for state one tick fresher.
                    # A pid that vanishes mid-tick drops one tick later;
                    # the 300s cooldown above suppresses re-grants meanwhile,
                    # and grants only ever act on this same fresh snapshot.
                    live = {c.get("pid") for c in live_now}
                    handled = {p: t for p, t in handled.items() if p in live}
        except Exception as e:
            log("loop error:", repr(e))
        time.sleep(1.2)

if __name__ == "__main__":
    main()
