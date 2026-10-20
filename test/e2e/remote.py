#!/usr/bin/env python3
"""Virtual Bluetooth remote for the end-to-end test (uinput, bus 0005).
Usage: remote.py <work dir> <device name>
Commands arrive as the file <work dir>/cmd ("tap CODE", "hold CODE SECONDS", "reconnect", "quit");
it is deleted once executed."""
import os
import sys
import time

from evdev import UInput, ecodes as e

work, name = sys.argv[1], sys.argv[2]
cmd_path = os.path.join(work, "cmd")
keys = [e.KEY_PAGEDOWN, e.KEY_PAGEUP, e.KEY_VOLUMEUP, e.KEY_VOLUMEDOWN, e.KEY_A, e.KEY_S, e.KEY_D,
        e.KEY_LEFT, e.KEY_RIGHT]


def make():
    return UInput({e.EV_KEY: keys}, name=name, bustype=e.BUS_BLUETOOTH, vendor=0x1234, product=0x5678)


def key(ui, code, value):
    ui.write(e.EV_KEY, code, value)
    ui.syn()


ui = make()
open(os.path.join(work, "remote-ready"), "w").close()
deadline = time.time() + 300
while time.time() < deadline:
    try:
        with open(cmd_path) as f:
            parts = f.read().split()
    except FileNotFoundError:
        time.sleep(0.05)
        continue
    if not parts:
        time.sleep(0.05)
        continue
    if parts[0] == "quit":
        os.remove(cmd_path)
        break
    if parts[0] == "tap":
        key(ui, int(parts[1]), 1)
        time.sleep(0.08)
        key(ui, int(parts[1]), 0)
    elif parts[0] == "hold":
        key(ui, int(parts[1]), 1)
        time.sleep(float(parts[2]))
        key(ui, int(parts[1]), 0)
    elif parts[0] == "reconnect":
        ui.close()
        time.sleep(1)
        ui = make()
    os.remove(cmd_path)
ui.close()
