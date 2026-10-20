--[[ Shared state of the Bluetooth remote plugin (once per KOReader process).

Plugins are instantiated per UI (file manager, every opened book), but devices, the mapping and
the hooks into input handling must exist only once – hence this module.

Buttons arrive on two paths, both end up in Input:handleKeyBoardEv and from there in the mapping:
1. Via InkView (like all keys on PocketBook): what the firmware forwards as EVT_KEYPRESS(_EXT).
   On the PocketBook Era a paired remote's buttons arrive this way (e.g. Left/Right = 105/106).
2. Directly: reading Bluetooth input devices under /dev/input (btremote_evdev). For this the input
   wait function (input.waitForEvent) is split into 50 ms slices with non-blocking reads in between.
   InkView polls at 20 ms anyway, so this costs hardly any power.
   Only on PocketBook without raw_input (there KOReader reads /dev/input itself) – or in tests
   (BTREMOTE_TEST_NAME: only the device with exactly this name, so real devices stay untouched).
   On the Era the device nodes belong to root and KOReader runs as `reader`: "no access".
Connecting automatically (btremote_bluez): the firmware does not reconnect a paired remote after
power-off; the plugin calls Device1.Connect via D-Bus for paired input devices – after start and
wake-up every 10 s for 3 minutes, then every 2 minutes; once connected it only checks.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("ffi/util")

local K = require("btremote_keys")
local E = require("btremote_evdev")
local Z = require("btremote_bluez")

local Core = {
    updated = false,
    installed = false,
    devices = {},  -- [path] = { name, fd, grabbed, status }
    log = {},      -- recent key events (key log)
    logged = 0,    -- keys written to crash.log (limited)
}

local LOG_MAX = 30
local SLICE_US = 50000
local RESCAN_EMPTY_S = 3   -- without an open device
local RESCAN_OPEN_S = 15   -- with an open device (further devices)
local TEST_NAME = os.getenv("BTREMOTE_TEST_NAME")
local TEST_DBUS = os.getenv("BTREMOTE_TEST_DBUS") -- dbus-send replacement for tests
if TEST_DBUS then Z.DBUS_SEND = TEST_DBUS end
local CONNECT_TIMEOUT_S = 30
local EAGER_S = 180        -- try often for this long after start/wake-up
local EAGER_EVERY_S = 10
local CALM_EVERY_S = 120   -- afterwards, while a device is missing
local CHECK_EVERY_S = 60   -- all connected: just check

local function now()
    local s, u = util.gettime()
    return s + u / 1e6
end

function Core:load()
    if self.settings then return end
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/btremote.lua")
    self.enabled = self.settings:nilOrTrue("enabled")
    self.grab = self.settings:nilOrTrue("grab")
    self.ignored = self.settings:readSetting("ignored") or {}
    self.buttons = self.settings:readSetting("buttons") or K.defaultButtons()
    self.long_ms = self.settings:readSetting("long_ms") or 600
    self.autoconnect = self.settings:nilOrTrue("autoconnect")
    self.pending = {}
    self.machine = K.new{
        now = now,
        schedule = function(delay, fn)
            UIManager:scheduleIn(delay, fn)
            return fn
        end,
        unschedule = function(fn) UIManager:unschedule(fn) end,
        run = function(actions, code, long)
            logger.dbg("btremote: key", code, long and "long" or "short")
            UIManager:nextTick(function() Dispatcher:execute(actions) end)
        end,
        buttons = self.buttons,
        long_ms = self.long_ms,
    }
end

function Core:save()
    if not self.settings or not self.updated then return end
    self.settings:saveSetting("enabled", self.enabled)
    self.settings:saveSetting("grab", self.grab)
    self.settings:saveSetting("ignored", self.ignored)
    self.settings:saveSetting("buttons", self.buttons)
    self.settings:saveSetting("long_ms", self.long_ms)
    self.settings:saveSetting("autoconnect", self.autoconnect)
    self.settings:flush()
    self.updated = false
end

function Core:setLongMs(ms)
    self.long_ms = ms
    self.machine.long_ms = ms
    self.updated = true
end

function Core:resetButtons()
    self.buttons = K.defaultButtons()
    self.machine.buttons = self.buttons
    self.updated = true
end

function Core:directAllowed()
    if TEST_NAME then return true end
    return Device:isPocketBook() and not Device.input.raw_input
end

function Core:pushLog(code, value, direct, devname, handled)
    if value == 2 then return end
    table.insert(self.log, 1, {
        t = os.date("%H:%M:%S"),
        code = code, value = value, direct = direct, dev = devname, handled = handled,
    })
    self.log[LOG_MAX + 1] = nil
end

-- Devices read directly

function Core:closeDevice(path, keep_entry)
    local d = self.devices[path]
    if not d then return end
    if d.fd then
        if d.grabbed then E.grab(d.fd, false) end
        E.close(d.fd)
    end
    d.fd, d.grabbed = nil, false
    if not keep_entry then self.devices[path] = nil end
end

function Core:closeAll()
    for path in pairs(self.devices) do self:closeDevice(path) end
    self.machine:releaseAll()
end

function Core:hasOpenDevice()
    for _, d in pairs(self.devices) do
        if d.fd then return true end
    end
    return false
end

function Core:rescan()
    self.last_scan = now()
    local seen = {}
    for _, info in ipairs(E.scan()) do
        if not TEST_NAME or info.name == TEST_NAME then
            seen[info.path] = true
            local d = self.devices[info.path]
            if d and d.name ~= info.name then
                -- a different device under the same number
                self:closeDevice(info.path)
                d = nil
            end
            if not d then
                d = { name = info.name, uniq = info.uniq }
                self.devices[info.path] = d
            end
            if self.ignored[info.name] or not self.enabled then
                if d.fd then self:closeDevice(info.path, true) end
                d.status = self.ignored[info.name] and "ignored" or "off"
            elseif not d.fd then
                local fd, err = E.open(info.path)
                if fd then
                    d.fd = fd
                    d.grabbed = self.grab and E.grab(fd, true) or false
                    d.status = d.grabbed and "open, exclusive" or "open"
                    logger.info("btremote: opened", info.path, info.name, d.grabbed and "(exclusive)" or "")
                else
                    if d.status ~= err then
                        logger.warn("btremote:", info.path, info.name, err)
                    end
                    d.status = err
                end
            elseif d.grabbed ~= self.grab then
                d.grabbed = E.grab(d.fd, self.grab) and self.grab
                d.status = d.grabbed and "open, exclusive" or "open"
            end
        end
    end
    for path in pairs(self.devices) do
        if not seen[path] then
            logger.info("btremote: disconnected", path)
            self:closeDevice(path)
        end
    end
end

-- Non-blocking read; returns a list of events or nil
function Core:poll()
    if self.suspended then return nil end
    local due = self:hasOpenDevice() and RESCAN_OPEN_S or RESCAN_EMPTY_S
    if not self.last_scan or now() - self.last_scan >= due then
        self:rescan()
    end
    local all
    for path, d in pairs(self.devices) do
        if d.fd then
            local evs, gone = E.read(d.fd)
            if evs then
                for _, ev in ipairs(evs) do
                    ev.btremote = d.name
                    all = all or {}
                    all[#all + 1] = ev
                end
            end
            if gone then
                logger.info("btremote: device gone", path, d.name)
                self:closeDevice(path)
                self.last_scan = nil -- rescan right away
            end
        end
    end
    return all
end

function Core:suspend()
    self.suspended = true
    self:closeAll()
    UIManager:unschedule(self.auto_tick)
end

function Core:resume()
    self.suspended = false
    self.pending = {} -- attempts from before standby no longer count
    self:ensureKeyHook()
    self.last_scan = nil
    self:startAutoConnect()
end

-- Connecting automatically

function Core:bluezAllowed()
    return TEST_DBUS ~= nil or Device:isPocketBook()
end

-- One round: query state, connect missing devices; returns whether one is missing
function Core:autoConnectOnce()
    local st = Z.query()
    self.bluez = st
    -- BlueZ not up yet (on the Era bluetoothd starts ~10 s after KOReader) or Bluetooth off:
    -- keep trying at the short interval
    if not st then return true end
    local powered = false
    for _, a in ipairs(st.adapters) do
        if a.powered then powered = true end
    end
    if not powered then return true end
    local missing = false
    local t = now()
    for _, dev in ipairs(st.devices) do
        if Z.wanted(dev) and not self.ignored[dev.name] then
            if dev.connected then
                if self.pending[dev.path] then
                    logger.info("btremote: connected", dev.name)
                end
                self.pending[dev.path] = nil
            else
                missing = true
                local last = self.pending[dev.path]
                if not last or t - last > CONNECT_TIMEOUT_S + 2 then
                    self.pending[dev.path] = t
                    logger.dbg("btremote: connecting", dev.name, dev.path)
                    Z.connect(dev.path, CONNECT_TIMEOUT_S)
                end
            end
        end
    end
    return missing
end

function Core:startAutoConnect()
    if not self:bluezAllowed() then return end
    self.eager_until = now() + EAGER_S
    self.auto_tick = self.auto_tick or function()
        if self.suspended or not self.enabled or not self.autoconnect then return end
        self:ensureKeyHook()
        local missing = self:autoConnectOnce()
        local delay = CHECK_EVERY_S
        if missing then
            delay = now() < self.eager_until and EAGER_EVERY_S or CALM_EVERY_S
        end
        UIManager:scheduleIn(delay, self.auto_tick)
    end
    UIManager:unschedule(self.auto_tick)
    UIManager:scheduleIn(1, self.auto_tick)
end

function Core:setAutoConnect(on)
    self.autoconnect = on
    self.updated = true
    if on then self:startAutoConnect() else UIManager:unschedule(self.auto_tick) end
end

-- Hooks into input handling (once)

--[[ Hook in Input:handleKeyBoardEv. Input:inhibitInput() stores the handler in _key_ev_handler,
installs its own meanwhile and restores the stored one on release. When hooking while input is
inhibited (as at startup on the Era: "Inhibiting user input" … "Restoring user input handling"),
the hook must go into _key_ev_handler, otherwise the release throws it out again. The timer also
checks regularly whether the hook is still in place. ]]
function Core:keyHooked()
    local input = Device.input
    return rawget(input, "handleKeyBoardEv") == self.key_hook or rawget(input, "_key_ev_handler") == self.key_hook
end

function Core:ensureKeyHook()
    if self:keyHooked() then return end
    local input = Device.input
    local field = rawget(input, "_key_ev_handler") and "_key_ev_handler" or "handleKeyBoardEv"
    local orig_key = input[field]
    self.key_hook = function(this, ev)
        local direct = ev.btremote ~= nil
        local handled = self.enabled and self.machine:feed(ev.code, ev.value, direct)
        self:pushLog(ev.code, ev.value, direct, ev.btremote, handled)
        if ev.value == 1 and self.logged < 40 then
            self.logged = self.logged + 1
            logger.info("btremote: key", ev.code, direct and ev.btremote or "InkView", handled and "mapped" or "passed on")
        end
        if handled then return end
        return orig_key(this, ev)
    end
    input[field] = self.key_hook
    logger.info("btremote: key hook installed", field == "_key_ev_handler" and "(while input inhibited)" or "")
end

function Core:install()
    if self.installed then return end
    self.installed = true
    self:load()
    local input = Device.input

    self:ensureKeyHook()

    self:startAutoConnect()
    if not self:directAllowed() then
        logger.info("btremote: InkView path only (no direct reading of /dev/input on this device)")
        return
    end
    local imp = input.input
    local orig_wait = imp.waitForEvent
    local ETIME = require("ffi").C.ETIME
    imp.waitForEvent = function(sec, usec)
        if not self.enabled then return orig_wait(sec, usec) end
        local deadline = sec and now() + sec + (usec or 0) / 1e6
        while true do
            local evs = self:poll()
            if evs then return true, evs end
            local slice = SLICE_US
            if deadline then
                local left = math.floor((deadline - now()) * 1e6)
                if left <= 0 then return false, ETIME end
                slice = math.min(slice, left)
            end
            local ok, ev, extra = orig_wait(math.floor(slice / 1e6), slice % 1000000)
            if ok ~= false or ev ~= ETIME or extra ~= nil then
                return ok, ev, extra
            end
        end
    end
    logger.info("btremote: reading Bluetooth input devices directly", TEST_NAME and ("(test: " .. TEST_NAME .. ")") or "")
end

function Core:setEnabled(on)
    self.enabled = on
    self.updated = true
    if not on then self:closeAll() else self:startAutoConnect() end
    self.last_scan = nil
end

function Core:setGrab(on)
    self.grab = on
    self.updated = true
    self.last_scan = nil
end

function Core:setIgnored(name, on)
    self.ignored[name] = on or nil
    self.updated = true
    self.last_scan = nil
end

return Core
