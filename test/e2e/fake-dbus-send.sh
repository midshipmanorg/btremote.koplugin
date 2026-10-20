#!/bin/sh
# dbus-send replacement for the end-to-end test: BlueZ with one paired remote.
# State in $BTTEST_DIR/bluez-connected (0/1); Connect is counted in $BTTEST_DIR/connects and connects.
here="$(cd "$(dirname "$0")" && pwd)"
state="$BTTEST_DIR/bluez-connected"
[ -f "$state" ] || echo 0 > "$state"
# bluez-down: bluetoothd is not running (yet)
[ -f "$BTTEST_DIR/bluez-down" ] && exit 1
case "$*" in
*GetManagedObjects*)
    if [ "$(cat "$state")" = 1 ]; then v=true; else v=false; fi
    awk -v v="$v" '/string "Connected"/ { print; getline; sub(/boolean (true|false)/, "boolean " v) } { print }' \
        "$here/../data/bluez-objects.txt"
    ;;
*Device1.Connect*)
    echo "$*" >> "$BTTEST_DIR/connects"
    echo 1 > "$state"
    ;;
*) exit 1 ;;
esac
