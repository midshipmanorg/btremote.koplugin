-- Unit tests without KOReader: luajit test/unit.lua (from the plugin directory)
local here = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = here .. "/../?.lua;" .. package.path

local ffi = require("ffi")
local K = require("btremote_keys")
local E = require("btremote_evdev")
local Z = require("btremote_bluez")

local fails, n = 0, 0
local function ok(cond, msg)
    n = n + 1
    if cond then
        print("ok   " .. msg)
    else
        fails = fails + 1
        print("FAIL " .. msg)
    end
end

-- state machine with a fake clock and timers
local function machine(buttons)
    local clock, timers, runs = 0, {}, {}
    local m = K.new{
        now = function() return clock end,
        schedule = function(d, fn) local t = { at = clock + d, fn = fn } timers[#timers + 1] = t return t end,
        unschedule = function(t) t.dead = true end,
        run = function(actions, code, long) runs[#runs + 1] = { actions = actions, code = code, long = long } end,
        buttons = buttons,
        long_ms = 600,
    }
    local function advance(s)
        clock = clock + s
        for _i, t in ipairs(timers) do
            if not t.dead and not t.done and t.at <= clock then t.done = true t.fn() end
        end
    end
    return m, runs, advance
end

do
    local m, runs = machine(K.defaultButtons())
    ok(m:feed(109, 1, true) == true and #runs == 1 and runs[1].actions.page_jmp == 1, "Page down turns the page forward on key down")
    ok(m:feed(109, 2, true) == true and #runs == 1, "repeat consumed, triggers nothing")
    ok(m:feed(109, 0, true) == true and #runs == 1, "release without long mapping triggers nothing")
    ok(m:feed(115, 1, true) and runs[2].actions.page_jmp == -1, "Volume up turns the page back")
    ok(m:feed(30, 1, true) == false, "unmapped key (A) is passed on")
end

do
    local buttons = { ["109"] = { short = { page_jmp = 1 }, long = { next_chapter = true } } }
    local m, runs, advance = machine(buttons)
    m:feed(109, 1, true)
    ok(#runs == 0, "with long mapping: key down waits")
    advance(0.2)
    m:feed(109, 0, true)
    ok(#runs == 1 and runs[1].long == false and runs[1].actions.page_jmp == 1, "released early → short action")
    advance(1)
    ok(#runs == 1, "timer dropped after short press")
    m:feed(109, 1, true)
    advance(0.7)
    ok(#runs == 2 and runs[2].long == true and runs[2].actions.next_chapter, "held → long action")
    m:feed(109, 0, true)
    ok(#runs == 2, "release after long action triggers nothing")
end

do
    local buttons = { ["114"] = { long = { toggle_bookmark = true } } }
    local m, runs, advance = machine(buttons)
    m:feed(114, 1, true)
    m:feed(114, 0, true)
    ok(#runs == 0, "long mapping only: short press does nothing")
    m:feed(114, 1, true)
    advance(0.61)
    ok(#runs == 1 and runs[1].long, "long mapping only: held triggers")
end

do
    local m, runs, advance = machine(K.defaultButtons())
    m:feed(109, 1, true)
    ok(m:feed(109, 1, false) == true and #runs == 1, "same key shortly after via InkView: dropped")
    advance(0.5)
    ok(m:feed(109, 1, false) == true and #runs == 2, "via InkView later: counts again")
end

do
    local m, runs = machine(K.defaultButtons())
    local got
    m:learn(function(code, direct) got = { code = code, direct = direct } end)
    ok(m:feed(330, 1, false) == false and got == nil, "learning skips touch codes (BTN_TOUCH)")
    ok(m:feed(109, 1, true) == true and got and got.code == 109 and got.direct and #runs == 0, "learning captures the key instead of turning the page")
    ok(m:feed(109, 0, true) == true and #runs == 0, "release of the learned key swallowed")
    ok(m:feed(109, 1, true) and #runs == 1, "afterwards the mapping applies again")
end

do
    ok(K.keyName(115) == "Volume up" and K.keyName(-25) == "InkView key 25" and K.keyName(999) == "Key 999", "key names")
    local de = { ["Volume up"] = "Lauter", ["Key %1"] = "Taste %1" }
    ok(K.keyName(115, function(x) return de[x] or x end) == "Lauter" and K.keyName(999, function(x) return de[x] or x end) == "Taste 999",
        "key names translated")
    ok(K.hasActions({ page_jmp = 1 }) and not K.hasActions({ settings = { order = {} } }) and not K.hasActions(nil), "hasActions")
    local d = K.defaultButtons()
    d["109"].short.page_jmp = 5
    ok(K.default_buttons["109"].short.page_jmp == 1, "default mapping is copied, not shared")
end

-- device scan against a fake sysfs
do
    local root = os.tmpname()
    os.remove(root)
    local function mk(node, bus, name, keys)
        local d = root .. "/sys/" .. node .. "/device"
        os.execute(("mkdir -p '%s/id' '%s/capabilities'"):format(d, d))
        local function w(p, s) local f = assert(io.open(d .. "/" .. p, "w")) f:write(s .. "\n") f:close() end
        w("id/bustype", bus)
        w("name", name)
        w("uniq", "aa:bb")
        w("capabilities/key", keys)
    end
    mk("event3", "0018", "Touchscreen", "400 0 0 0")
    mk("event7", "0005", "BT Page Turner", "1c000000000000 0")
    mk("event12", "0005", "BT Speaker", "0")
    mk("event10", "0005", "BT Keyboard", "ffff ffffffff")
    os.execute(("mkdir -p '%s/sys/input5'"):format(root))
    E.sysfs, E.devdir = root .. "/sys", "/dev/input"
    local found = E.scan()
    ok(#found == 2 and found[1].name == "BT Page Turner" and found[1].path == "/dev/input/event7"
        and found[2].node == "event10", "scan: Bluetooth with keys only, sorted by number")

    -- reading: file with two events (EV_KEY + EV_SYN)
    local evs = ffi.new("struct input_event[2]")
    evs[0].type, evs[0].code, evs[0].value = 1, 115, 1
    evs[0].time.tv_sec = 42
    evs[1].type, evs[1].code, evs[1].value = 0, 0, 0
    local f = assert(io.open(root .. "/ev", "wb"))
    f:write(ffi.string(evs, ffi.sizeof(evs)))
    f:close()
    local fd = E.open(root .. "/ev")
    local list, gone = E.read(fd)
    E.close(fd)
    ok(list and #list == 1 and list[1].code == 115 and list[1].value == 1 and list[1].time.sec == 42 and gone,
        "read: EV_KEY only, end of file = device gone")
    local fd2, err = E.open(root .. "/missing")
    ok(fd2 == nil and err ~= nil, "open: error reported")
    os.execute(("rm -rf '%s'"):format(root))
end

-- BlueZ: real output from a PocketBook Era (anonymised), remote connected
do
    local f = assert(io.open(here .. "/data/bluez-objects.txt"))
    local st = Z.parseObjects(f:read("*a"))
    f:close()
    ok(#st.adapters == 1 and st.adapters[1].powered == true and st.adapters[1].path == "/org/bluez/hci0", "BlueZ: adapter powered")
    local d = st.devices[1]
    ok(#st.devices == 1 and d.name == "HBTR001-K" and d.address == "AA:BB:CC:DD:EE:01"
        and d.path == "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01", "BlueZ: remote found")
    ok(d.paired and d.trusted and d.connected and not d.blocked and d.hid and d.icon == "input-keyboard", "BlueZ: paired, connected, HID")
    ok(Z.wanted(d), "BlueZ: connected automatically")
    local st2 = Z.parseObjects([[
      dict entry(
         object path "/org/bluez/hci0/dev_11_22_33_44_55_66"
         array [
            dict entry(
               string "org.bluez.Device1"
               array [
                  dict entry(
                     string "Name"
                     variant                         string "Headphones"
                  )
                  dict entry(
                     string "Paired"
                     variant                         boolean true
                  )
                  dict entry(
                     string "UUIDs"
                     variant                         array [
                           string "0000110b-0000-1000-8000-00805f9b34fb"
                        ]
                  )
                  dict entry(
                     string "Connected"
                     variant                         boolean false
                  )
               ]
            )
         ]
      )]])
    ok(#st2.devices == 1 and st2.devices[1].name == "Headphones" and not st2.devices[1].hid and not Z.wanted(st2.devices[1]),
        "BlueZ: headphones are not connected")
    ok(Z.connectCommand("/org/bluez/hci0/dev_X", 30) ==
        "dbus-send --system --print-reply --reply-timeout=30000 --dest=org.bluez '/org/bluez/hci0/dev_X' org.bluez.Device1.Connect >/dev/null 2>&1 &",
        "BlueZ: Connect runs in the background")
    ok(#Z.parseObjects("").devices == 0, "BlueZ: empty output")
end

print(("%d tests, %d failures"):format(n, fails))
os.exit(fails == 0 and 0 or 1)
