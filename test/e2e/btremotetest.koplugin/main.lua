--[[ End-to-end test of the Bluetooth remote plugin inside a running KOReader (see ../run.sh).
Only active with BTTEST_DIR; the remote is a uinput device (remote.py, Bluetooth bus) driven via the
file BTTEST_DIR/cmd. Results go to BTTEST_DIR/results.txt, then KOReader quits. ]]
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")

local Test = WidgetContainer:extend{ name = "btremotetest", is_doc_only = false }
local DIR = os.getenv("BTTEST_DIR")
local NAME = os.getenv("BTREMOTE_TEST_NAME")
local started = false
local lines, failures = {}, 0

local function log(ok, msg)
    if not ok then failures = failures + 1 end
    lines[#lines + 1] = (ok and "ok   " or "FAIL ") .. msg
    local f = io.open(DIR .. "/results.txt", "w")
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
end

local function exists(p) return lfs.attributes(p, "mode") ~= nil end
local function cmd(s)
    local f = io.open(DIR .. "/cmd.tmp", "w")
    f:write(s)
    f:close()
    os.rename(DIR .. "/cmd.tmp", DIR .. "/cmd")
end

local function finish()
    log(failures == 0, "END: " .. failures .. " failures")
    cmd("quit")
    UIManager:scheduleIn(0.5, function() UIManager:quit() end)
end

local steps, current = {}, 0
local function step(name, fn) steps[#steps + 1] = { name = name, fn = fn } end
local function nextStep()
    current = current + 1
    local s = steps[current]
    if not s then return finish() end
    UIManager:scheduleIn(0.3, function()
        local ok, err = xpcall(s.fn, debug.traceback)
        if not ok then
            log(false, "crash in \"" .. s.name .. "\": " .. tostring(err))
            finish()
        end
    end)
end
local function waitFor(what, cond, timeout, after)
    local t0 = os.time()
    local function poll()
        local ok, v = pcall(cond)
        if ok and v then return after() end
        if os.time() - t0 > (timeout or 20) then
            log(false, "timeout: " .. what)
            return finish()
        end
        UIManager:scheduleIn(0.2, poll)
    end
    poll()
end
-- command to the remote, wait until executed, then another `settle` seconds
local function send(s, settle, after)
    cmd(s)
    waitFor("remote: " .. s, function() return not exists(DIR .. "/cmd") end, 10, function()
        UIManager:scheduleIn(settle or 0.6, after)
    end)
end

local Core = require("btremote_core")
local function reader() return require("apps/reader/readerui").instance end
local function page() return reader().document:getCurrentPage() end
local function device()
    for _, d in pairs(Core.devices) do
        if d.name == NAME then return d end
    end
end
local function connected() local d = device() return d and d.fd and d.grabbed end

local p0

function Test:init()
    if not DIR or started or self.ui.document then return end
    started = true
    UIManager:scheduleIn(2, nextStep)
end

step("open book, remote connected", function()
    require("apps/reader/readerui"):showReader(DIR .. "/device/juliet.epub")
    waitFor("book open", function() local r = reader() return r and r.document and r.btremote end, 30, function()
        waitFor("remote connected", connected, 15, function()
            local d = device()
            log(true, "connected: " .. d.name .. " (" .. d.status .. ")")
            -- only send keys once KOReader grabbed the device – otherwise the desktop would see them too;
            -- take the page only after the document settled (restoring the reading position)
            UIManager:scheduleIn(2, nextStep)
        end)
    end)
end)

step("Page down turns forward", function()
    p0 = page()
    send("tap 109", 0.8, function()
        log(page() == p0 + 1, "page " .. p0 .. " → " .. page())
        nextStep()
    end)
end)

step("Volume up turns back", function()
    send("tap 115", 0.8, function()
        log(page() == p0, "page back to " .. page())
        nextStep()
    end)
end)

step("short and long on one button", function()
    p0 = page()
    Core.buttons["30"] = { short = { page_jmp = 1 }, long = { page_jmp = 3 } }
    send("tap 30", 0.8, function()
        log(page() == p0 + 1, "A short: +1 → " .. page())
        send("hold 30 1.0", 0.8, function()
            log(page() == p0 + 4, "A long: +3 → " .. page())
            nextStep()
        end)
    end)
end)

step("unmapped key does nothing, shows in the key log", function()
    local before = page()
    send("tap 31", 0.8, function()
        local e = Core.log[1]
        log(page() == before and e and e.code == 31 and e.direct and not e.handled,
            "S: page stays, log: " .. (e and (e.code .. (e.handled and " mapped" or " passed on")) or "empty"))
        nextStep()
    end)
end)

step("learning", function()
    local before, got = page(), nil
    Core.machine:learn(function(code, direct) got = { code = code, direct = direct } end)
    send("tap 32", 0.8, function()
        log(got and got.code == 32 and got.direct and page() == before, "D learned: " .. tostring(got and got.code))
        Core.buttons["32"] = { short = { page_jmp = -1 } }
        send("tap 32", 0.8, function()
            log(page() == before - 1, "D mapped afterwards: back → " .. page())
            nextStep()
        end)
    end)
end)

step("connection lost and back", function()
    send("reconnect", 0.2, function()
        waitFor("reconnected", connected, 15, function()
            local before = page()
            send("tap 109", 0.8, function()
                log(page() == before + 1, "after reconnect: forward → " .. page())
                nextStep()
            end)
        end)
    end)
end)

step("standby closes, wake-up reopens", function()
    Core:suspend()
    log(device() == nil or device().fd == nil, "closed in standby")
    Core:resume()
    waitFor("connected after wake-up", connected, 15, function()
        local before = page()
        send("tap 109", 0.8, function()
            log(page() == before + 1, "after wake-up: forward → " .. page())
            nextStep()
        end)
    end)
end)

step("disabled: device released, then back", function()
    -- never send keys while the device is not grabbed (they would reach the desktop)
    Core:setEnabled(false)
    UIManager:scheduleIn(0.5, function()
        log(not connected(), "off: device closed")
        Core:setEnabled(true)
        waitFor("on again", connected, 15, function()
            local before = page()
            send("tap 109", 0.8, function()
                log(page() == before + 1, "on again: forward → " .. page())
                nextStep()
            end)
        end)
    end)
end)

local function readfile(p)
    local f = io.open(p)
    if not f then return "" end
    local c = f:read("*a")
    f:close()
    return c
end
local function connects() local _, c = readfile(DIR .. "/connects"):gsub("\n", "") return c end

step("connect automatically after start", function()
    -- start: remote disconnected according to (fake) BlueZ → Connect, then connected, no further attempts
    waitFor("Connect called", function() return connects() >= 1 end, 15, function()
        log(readfile(DIR .. "/connects"):find("dev_AA_BB_CC_DD_EE_01", 1, true) ~= nil, "Connect for the remote")
        UIManager:scheduleIn(12, function()
            log(connects() == 1, "connected: no further attempt (" .. connects() .. ")")
            local d = Core.bluez and Core.bluez.devices[1]
            log(d and d.connected, "state connected")
            nextStep()
        end)
    end)
end)

step("connection lost → reconnect", function()
    local f = io.open(DIR .. "/bluez-connected", "w")
    f:write("0")
    f:close()
    -- after wake-up the short interval applies again
    Core:suspend()
    Core:resume()
    waitFor("connected again", function() return connects() >= 2 end, 15, function()
        log(true, "reconnected after wake-up (" .. connects() .. " attempts)")
        nextStep()
    end)
end)

step("BlueZ starts after KOReader", function()
    -- like on the Era after power-on: the first queries fail, then bluetoothd is up
    io.open(DIR .. "/bluez-down", "w"):close()
    local f = io.open(DIR .. "/bluez-connected", "w")
    f:write("0")
    f:close()
    local before = connects()
    Core:suspend()
    Core:resume()
    UIManager:scheduleIn(3, function()
        os.remove(DIR .. "/bluez-down")
        local t0 = os.time()
        waitFor("Connect after BlueZ start", function() return connects() > before end, 15, function()
            log(os.time() - t0 <= 12, "connected " .. (os.time() - t0) .. " s after BlueZ came up")
            nextStep()
        end)
    end)
end)

step("device unticked → not connected", function()
    local f = io.open(DIR .. "/bluez-connected", "w")
    f:write("0")
    f:close()
    Core:setIgnored("HBTR001-K", true)
    local before = connects()
    UIManager:scheduleIn(12, function()
        log(connects() == before, "unticked: no Connect")
        Core:setIgnored("HBTR001-K", false)
        nextStep()
    end)
end)

step("key hook survives the input inhibit at startup", function()
    -- like on the Era: KOReader inhibits input, the plugin hooks in, input is restored
    local input = require("device").input
    input.handleKeyBoardEv = nil -- back to the class method, without hook
    Core.key_hook = nil
    input:inhibitInput(true)
    Core:ensureKeyHook()
    input:inhibitInput(false)
    log(Core:keyHooked(), "still hooked after restore")
    local before = page()
    send("tap 109", 0.8, function()
        log(page() == before + 1, "after inhibit: forward → " .. page())
        nextStep()
    end)
end)

step("build the whole menu", function()
    local plugin = reader().btremote
    local count, depth_max = 0, 0
    local function walk(items, depth)
        depth_max = math.max(depth_max, depth)
        for _, it in ipairs(items) do
            count = count + 1
            if it.text_func then it.text_func() end
            if it.checked_func then it.checked_func() end
            if it.enabled_func then it.enabled_func() end
            -- do not walk the Dispatcher submenus (actions per button) to full depth
            if it.sub_item_table_func and depth < 3 then walk(it.sub_item_table_func(), depth + 1) end
        end
    end
    local m = {}
    plugin:addToMainMenu(m)
    walk(m.btremote.sub_item_table_func(), 1)
    log(count > 20 and depth_max == 3, "menu: " .. count .. " entries, depth " .. depth_max)
    local found = false
    for _, it in ipairs(plugin:deviceItems()) do
        if it.text_func and it.text_func():find("HBTR001-K", 1, true) then found = true end
    end
    log(found, "device list shows the paired remote")
    -- German via the built-in translation
    local gettext = require("gettext")
    local lang = gettext.current_lang
    gettext.current_lang = "de_DE"
    local de_items = plugin:menuItems()
    gettext.current_lang = lang
    log(de_items[1].text == "Fernbedienung verwenden", "German menu texts: " .. tostring(de_items[1].text))
    plugin:showLog()
    UIManager:scheduleIn(0.5, function()
        local top = UIManager:getTopmostVisibleWidget()
        log(top and top.title == require("btremote_i18n")("Key log"), "key log opened")
        if top then UIManager:close(top) end
        nextStep()
    end)
end)

return Test
