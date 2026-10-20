--[[ Bluetooth remote: page-turner remotes and other Bluetooth buttons on PocketBook.

Pairing is done by the firmware (Settings → Bluetooth). The plugin connects paired remotes
automatically via BlueZ, takes the buttons InkView forwards and – where permitted – reads Bluetooth
input devices from /dev/input directly. Mapping per button: short and long press, each with any
KOReader actions (Dispatcher). Unknown buttons can be learned; the key log shows what arrives.
Shared state and input hooks: btremote_core.lua; button logic: btremote_keys.lua.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui/widget/spinwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local _ = require("btremote_i18n")

local Core = require("btremote_core")
local K = require("btremote_keys")
local Z = require("btremote_bluez")

local BtRemote = WidgetContainer:extend{
    name = "btremote",
    is_doc_only = false,
}

function BtRemote:init()
    Core:install()
    -- per UI (book/file manager) check that the key hook is still in place
    UIManager:nextTick(function() Core:ensureKeyHook() end)
    self.ui.menu:registerToMainMenu(self)
end

function BtRemote:onSuspend()
    Core:suspend()
end

function BtRemote:onResume()
    Core:resume()
end

function BtRemote:onFlushSettings()
    Core:save()
end

function BtRemote:onCloseWidget()
    Core:save()
end

function BtRemote:addToMainMenu(menu_items)
    menu_items.btremote = {
        text = _("Bluetooth remote"),
        sorting_hint = "device",
        sub_item_table_func = function() return self:menuItems() end,
    }
end

local function actionText(actions)
    if not K.hasActions(actions) then return _("nothing") end
    return Dispatcher:menuTextFunc(actions)
end

local function sortedCodes()
    local codes = {}
    for key in pairs(Core.buttons) do codes[#codes + 1] = key end
    table.sort(codes, function(a, b) return tonumber(a) < tonumber(b) end)
    return codes
end

function BtRemote:deviceItems()
    local items = {}
    -- Paired input devices according to BlueZ (connection, automatic connecting)
    if Core:bluezAllowed() then
        local st = Z.query()
        Core.bluez = st
        for _i, dev in ipairs(st and st.devices or {}) do
            if Z.wanted(dev) then
                table.insert(items, {
                    text_func = function()
                        local state = dev.connected and _("connected") or _("disconnected")
                        if not Core.ignored[dev.name] and not dev.connected and Core.autoconnect then
                            state = state .. ", " .. _("connects automatically")
                        end
                        return T("%1 (%2)", dev.name, state)
                    end,
                    checked_func = function() return not Core.ignored[dev.name] end,
                    callback = function()
                        Core:setIgnored(dev.name, not Core.ignored[dev.name])
                    end,
                    help_text = _("Untick to neither connect nor use this device (e.g. a keyboard for typing)."),
                })
            end
        end
        if st == nil then
            table.insert(items, { text = _("BlueZ not reachable (Bluetooth off?)"), enabled = false })
        elseif #items == 0 then
            table.insert(items, {
                text = _("No paired remote. Pair it in the PocketBook settings under Bluetooth."),
                enabled = false,
            })
        end
        items[#items].separator = true
    end
    -- Device nodes under /dev/input read directly
    if Core:directAllowed() then
        Core:rescan()
        local paths = {}
        for path in pairs(Core.devices) do paths[#paths + 1] = path end
        table.sort(paths)
        for _i, path in ipairs(paths) do
            local d = Core.devices[path]
            table.insert(items, {
                text_func = function()
                    return T("%1: %2 (%3)", path:match("[^/]+$"), d.name, d.status and _(d.status) or "?")
                end,
                enabled = false,
            })
        end
    end
    if #items == 0 then
        table.insert(items, { text = _("No Bluetooth input devices found."), enabled = false })
    end
    return items
end

function BtRemote:buttonItems(key)
    local btn = Core.buttons[key]
    local function sub(slot)
        local items = {}
        Dispatcher:addSubMenu(Core, items, btn, slot)
        items.max_per_page = 9
        return items
    end
    return {
        {
            text_func = function() return T(_("Short press: %1"), actionText(btn.short)) end,
            sub_item_table_func = function() return sub("short") end,
        },
        {
            text_func = function() return T(_("Long press: %1"), actionText(btn.long)) end,
            sub_item_table_func = function() return sub("long") end,
            separator = true,
        },
        {
            text = _("Remove button"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                Core.buttons[key] = nil
                Core.updated = true
                touchmenu_instance:backToUpperMenu()
            end,
        },
    }
end

function BtRemote:learn(touchmenu_instance)
    local info = InfoMessage:new{
        text = _("Press the button on the remote now…"),
        timeout = 15,
        dismiss_callback = function() Core.machine:cancelLearn() end,
    }
    UIManager:show(info)
    Core.machine:learn(function(code, direct)
        Core.machine:cancelLearn()
        UIManager:close(info)
        local key = tostring(code)
        local known = Core.buttons[key] ~= nil
        local dialog
        local function set(actions)
            Core.buttons[key] = Core.buttons[key] or {}
            if actions then Core.buttons[key].short = actions end
            Core.updated = true
            UIManager:close(dialog)
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end
        dialog = ButtonDialog:new{
            title = T(_("%1 (code %2, %3)%4"), K.keyName(code, _), code,
                direct and _("read directly") or _("via InkView"),
                known and "\n" .. T(_("currently: %1"), actionText(Core.buttons[key].short)) or ""),
            buttons = {
                {
                    { text = _("Next page"), callback = function() set({ page_jmp = 1 }) end },
                    { text = _("Previous page"), callback = function() set({ page_jmp = -1 }) end },
                },
                {
                    { text = _("Next chapter"), callback = function() set({ next_chapter = true }) end },
                    { text = _("Previous chapter"), callback = function() set({ prev_chapter = true }) end },
                },
                {
                    { text = _("Decide later"), callback = function() set(nil) end },
                },
            },
        }
        UIManager:show(dialog)
    end)
end

function BtRemote:showLog()
    local lines = {}
    for _i, e in ipairs(Core.log) do
        table.insert(lines, T("%1  %2 %3  %4 (%5)  %6",
            e.t, e.value == 1 and "▼" or "▲", e.code, K.keyName(e.code, _),
            e.direct and (e.dev or _("direct")) or "InkView",
            e.handled and _("mapped") or _("passed on")))
    end
    if #lines == 0 then
        lines[1] = _("No button received yet. Press a button, then open this again.")
    end
    UIManager:show(TextViewer:new{
        title = _("Key log"),
        text = table.concat(lines, "\n"),
        monospace_font = true,
    })
end

function BtRemote:menuItems()
    local items = {
        {
            text = _("Use remote"),
            checked_func = function() return Core.enabled end,
            callback = function() Core:setEnabled(not Core.enabled) end,
        },
        {
            text = _("Devices"),
            enabled_func = function() return Core.enabled end,
            sub_item_table_func = function() return self:deviceItems() end,
        },
        {
            text = _("Connect automatically"),
            help_text = _("Reconnects paired remotes by itself after power-on and wake-up (the firmware does not): every 10 s for 3 minutes, then every 2 minutes. If the remote is asleep, press a button."),
            enabled_func = function() return Core.enabled and Core:bluezAllowed() end,
            checked_func = function() return Core.autoconnect end,
            callback = function() Core:setAutoConnect(not Core.autoconnect) end,
        },
        {
            text = _("Connect now"),
            enabled_func = function() return Core.enabled and Core:bluezAllowed() end,
            keep_menu_open = true,
            callback = function()
                Core.pending = {}
                Core:autoConnectOnce()
                Core:startAutoConnect()
                UIManager:show(InfoMessage:new{
                    text = _("Connecting… If the remote is asleep, press a button."),
                    timeout = 4,
                })
            end,
        },
        {
            text = _("Grab buttons exclusively"),
            help_text = _("The firmware no longer sees the remote's buttons (no double actions, no volume popup). Only while KOReader is in the foreground."),
            enabled_func = function() return Core.enabled and Core:directAllowed() end,
            checked_func = function() return Core.grab end,
            callback = function() Core:setGrab(not Core.grab) end,
            separator = true,
        },
        {
            text = _("Learn new button…"),
            enabled_func = function() return Core.enabled end,
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:learn(touchmenu_instance) end,
        },
        {
            text = _("Button mapping"),
            enabled_func = function() return Core.enabled end,
            sub_item_table_func = function()
                local sub = {}
                for _i, key in ipairs(sortedCodes()) do
                    local btn = Core.buttons[key]
                    table.insert(sub, {
                        text_func = function()
                            local s = T("%1: %2", K.keyName(key, _), actionText(btn.short))
                            if K.hasActions(btn.long) then
                                s = s .. T(_(" · long: %1"), actionText(btn.long))
                            end
                            return s
                        end,
                        sub_item_table_func = function() return self:buttonItems(key) end,
                    })
                end
                sub[#sub].separator = true
                table.insert(sub, {
                    text = _("Restore default mapping"),
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        Core:resetButtons()
                        touchmenu_instance:backToUpperMenu()
                    end,
                })
                return sub
            end,
        },
        {
            text_func = function() return T(_("Long-press duration: %1 ms"), Core.long_ms) end,
            enabled_func = function() return Core.enabled end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new{
                    title_text = _("Long press after"),
                    value = Core.long_ms, value_min = 300, value_max = 2000, value_step = 50,
                    value_hold_step = 250, unit = "ms", default_value = 600,
                    callback = function(spin)
                        Core:setLongMs(spin.value)
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
            separator = true,
        },
        {
            text = _("Key log"),
            help_text = _("Shows the last buttons with code and source – useful when a button does nothing."),
            keep_menu_open = true,
            callback = function() self:showLog() end,
        },
    }
    return items
end

return BtRemote
