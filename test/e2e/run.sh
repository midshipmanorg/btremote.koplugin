#!/bin/sh
# End-to-end test of the Bluetooth remote plugin in a real KOReader (desktop emulator, offscreen).
# A virtual remote (uinput, Bluetooth bus, unique test name) turns pages in a book; BlueZ is faked by
# fake-dbus-send.sh. Needs python-evdev, write access to /dev/uinput and read access to /dev/input
# (group input). The plugin only touches the device with exactly the test name (BTREMOTE_TEST_NAME).
# Usage: test/e2e/run.sh <koreader dir of a built emulator, e.g. koreader-emulator-x86_64-linux-gnu-debug/koreader>
#        (or KOREADER_DIR=…); BTTEST_EPUB=<book> (default: KOReader's test/juliet.epub)
set -e
here="$(cd "$(dirname "$0")" && pwd)"
plugin="$(cd "$here/../.." && pwd)"
KO="${1:-${KOREADER_DIR:-}}"
[ -n "$KO" ] && [ -x "$KO/reader.lua" ] || { echo "usage: $0 <koreader emulator dir> (no reader.lua in '$KO')" >&2; exit 2; }
EPUB="${BTTEST_EPUB:-$KO/../../test/juliet.epub}"
[ -f "$EPUB" ] || { echo "no test book: $EPUB (set BTTEST_EPUB)" >&2; exit 2; }
name="btremote-test-remote-$$"
rm -rf "$KO/plugins/btremote.koplugin" "$KO/plugins/btremotetest.koplugin" "$KO/settings/btremote.lua"
mkdir -p "$KO/plugins/btremote.koplugin"
cp "$plugin"/*.lua "$KO/plugins/btremote.koplugin/"
cp -r "$here/btremotetest.koplugin" "$KO/plugins/"
work="$(mktemp -d)"
mkdir -p "$work/device"
cp "$EPUB" "$work/device/juliet.epub"
python3 -I "$here/remote.py" "$work" "$name" > "$work/remote.log" 2>&1 &
rc=$!
i=0; while [ ! -e "$work/remote-ready" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
cd "$KO"
SDL_VIDEO_DRIVER=offscreen SDL_VIDEODRIVER=offscreen SDL_AUDIO_DRIVER=dummy \
  BTTEST_DIR="$work" BTREMOTE_TEST_NAME="$name" BTREMOTE_TEST_DBUS="$here/fake-dbus-send.sh" \
  timeout 120 ./reader.lua "$work/device" > "$work/koreader.log" 2>&1 || true
kill "$rc" 2>/dev/null || true
cat "$work/results.txt" 2>/dev/null || echo "no results"
grep -E "ERROR|btremote" "$work/koreader.log" | grep -v "^ffi" | tail -20
cat "$work/remote.log"
rm -rf "$KO/plugins/btremote.koplugin" "$KO/plugins/btremotetest.koplugin" "$KO/settings/btremote.lua"
grep -q "^ok   END" "$work/results.txt"
