# btremote.koplugin – Bluetooth page-turner remotes for KOReader on PocketBook

A [KOReader](https://github.com/koreader/koreader) plugin that makes cheap Bluetooth page-turner
remotes (and other Bluetooth buttons) usable on PocketBook e-readers.

Developed and tested on a **PocketBook Era** (firmware 6.10, BlueZ 5.52) with a "HBTR001-K"
remote (sold as "Bluetooth page turner for Kobo/BOOX"). Other PocketBook models with Bluetooth
should work the same way; reports are welcome.

## What it does

- **Reconnects the remote automatically.** The PocketBook firmware keeps the pairing but does not
  reconnect a remote after power-off or standby – you would have to reconnect it by hand every
  time. The plugin asks BlueZ (via D-Bus) to connect paired input devices: after start and wake-up
  every 10 s for 3 minutes, then every 2 minutes; once connected it only checks every minute.
  If the remote is asleep, press a button.
- **Turns pages.** The firmware forwards the remote's keys to KOReader, but KOReader ignores them
  on PocketBook. The plugin maps them: common page-turner codes are preset (Page down, Right, Down,
  Volume down, Next track, Space → next page; Page up, Left, Up, Volume up, Previous track →
  previous page).
- **Any action, short and long press.** Each button can trigger any KOReader action (the same list
  as for gestures) on short and on long press; the long-press duration is adjustable.
- **Learn unknown buttons** – press "Learn new button…", then the button, then pick an action.
- **Key log** shows the last buttons with code and source, useful when a button does nothing.
- Where KOReader may read `/dev/input` directly (running as root), it can also read the remote's
  device node itself and grab it exclusively, so the firmware no longer sees the buttons. On the
  Era this is not possible (KOReader runs as user `reader`); the buttons arrive via InkView there.
- English and German UI.

## Installation

1. Pair the remote in the PocketBook settings under Bluetooth.
2. Copy this directory to `applications/koreader/plugins/btremote.koplugin` on the device
   (USB), e.g. `git clone https://github.com/midshipmanorg/btremote.koplugin` into the
   `plugins` folder, or download the ZIP and rename the folder to `btremote.koplugin`.
   Only the `*.lua` files are needed on the device.
3. Restart KOReader. The settings are under ⚙ → Device → **Bluetooth remote**.

## Menu

| Item | |
|---|---|
| Use remote | master switch |
| Devices | paired remotes with state; untick to ignore a device (e.g. a keyboard) |
| Connect automatically / Connect now | the reconnect logic described above |
| Grab buttons exclusively | only where devices are read directly (see above) |
| Learn new button… / Button mapping | assign actions for short and long press |
| Long-press duration | 300–2000 ms, default 600 |
| Key log | last 30 buttons with code, source and whether they were mapped |

## How it works

- `btremote_bluez.lua` – lists BlueZ objects (`dbus-send … GetManagedObjects`) and calls
  `org.bluez.Device1.Connect` in the background for paired HID devices (UUID 0x1124/0x1812).
  On the Era the `reader` user is allowed to talk to `org.bluez` on the system bus.
- `btremote_core.lua` – hooks `Input:handleKeyBoardEv` (and survives KOReader's startup input
  inhibit, which otherwise restores the original handler), runs the reconnect timer and, where
  allowed, reads Bluetooth devices from `/dev/input` in 50 ms slices of the input wait loop.
- `btremote_keys.lua` – short/long press state machine, default mapping, key names.
- `btremote_evdev.lua` – finds Bluetooth input devices (bus 0005) in `/sys/class/input`.
- `btremote_i18n.lua` – the plugin's own translations (KOReader does not load plugin catalogs).

Settings are stored in `settings/btremote.lua`. With KOReader's debug logging enabled, the first
40 key presses are written to `crash.log` (`btremote: key …`).

## Tests

```sh
luajit test/unit.lua                                  # no KOReader needed
test/e2e/run.sh <koreader>/koreader-emulator-*/koreader   # real KOReader emulator, offscreen
```

The end-to-end test needs a built KOReader emulator, python-evdev and access to `/dev/uinput` and
`/dev/input` (group `input`). It creates a virtual Bluetooth remote, fakes BlueZ with
`test/e2e/fake-dbus-send.sh` and checks page turning, long press, learning, reconnecting, standby,
the startup input inhibit, the menu and the German translation. The plugin only touches the
virtual device (matched by name) during the test.

## Deutsch

Eine KOReader-Erweiterung für Bluetooth-Blätterfernbedienungen auf PocketBook-Readern, entwickelt
auf der PocketBook Era. Sie **verbindet die gekoppelte Fernbedienung nach dem Einschalten und
Aufwachen selbst** (die Firmware tut es nicht), **blättert mit ihren Tasten** (übliche Codes sind
vorbelegt) und erlaubt je Taste beliebige KOReader-Aktionen für kurzes und langes Drücken,
Anlernen unbekannter Tasten und ein Tastenprotokoll. Menü und Meldungen gibt es auf Deutsch.

Installation: Fernbedienung in den PocketBook-Einstellungen unter Bluetooth koppeln, diesen Ordner
als `applications/koreader/plugins/btremote.koplugin` auf das Gerät kopieren, KOReader neu starten.
Einstellungen unter ⚙ → Gerät → **Bluetooth-Fernbedienung**.

## License

AGPL-3.0, like KOReader – see [LICENSE](LICENSE).
