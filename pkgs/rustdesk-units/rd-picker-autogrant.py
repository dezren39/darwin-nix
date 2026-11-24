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
    run(["ydotool"] + list(args), timeout=8)

def calibrate():
    """ydotool absolute moves are scaled (observed x2.45). Measure it."""
    ydotool("mousemove", "--absolute", "-x", "100", "-y", "100")
    time.sleep(0.6)
    pos = cursorpos()
    if not pos or pos[0] == 0:
        return 2.45
    return pos[0] / 100.0

def click(x, y, scale):
    ydotool("mousemove", "--absolute", "-x", str(round(x / scale)),
            "-y", str(round(y / scale)))
    time.sleep(0.7)
    ydotool("click", "0xC0")
    time.sleep(0.7)

# evdev codes: SUPER_L=125; digit keys '1'..'9' = 2..10, '0' = 11
def goto_ws(n):
    if n is None or n < 1 or n > 10:
        return
    code = n + 1 if n < 10 else 11
    ydotool("key", "125:1", f"{code}:1", f"{code}:0", "125:0")
    time.sleep(0.9)

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
    scale = calibrate()
    log(f"ydotool scale={scale:.3f}")
    cur = active_ws()
    if ws and cur and ws != cur:
        goto_ws(ws)
    gone = None
    # candidate (row_rel_y, share_rel_x_from_right) pairs; first that closes wins
    for row_rel, share_off in ((150, 48), (130, 107), (170, 48)):
        click(x + w // 2, y + row_rel, scale)
        click(x + w - share_off, y + h - 30, scale)
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
    if ws and cur and ws != cur:
        goto_ws(cur)
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
                live_now = clients()
                if live_now is not None:
                    live = {c.get("pid") for c in live_now}
                    handled = {p: t for p, t in handled.items() if p in live}
        except Exception as e:
            log("loop error:", repr(e))
        time.sleep(1.2)

if __name__ == "__main__":
    main()
