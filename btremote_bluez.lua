--[[ Find paired Bluetooth input devices via BlueZ (D-Bus) and connect them.

On the PocketBook Era KOReader runs as user `reader`, which /etc/dbus-1/system.d/bluetooth.conf
allows to talk to org.bluez. The firmware does not reconnect a paired remote after power-off –
Device1.Connect does. A Connect to a sleeping LE device waits until it advertises again (button
press) or times out, hence it runs in the background.
No KOReader dependencies (the parser is testable with plain luajit).
]]

local Z = {}

Z.DBUS_SEND = "dbus-send"
-- Human Interface Device: classic (HIDP) and over LE (HOGP)
local HID_UUIDS = {
    ["00001124-0000-1000-8000-00805f9b34fb"] = true,
    ["00001812-0000-1000-8000-00805f9b34fb"] = true,
}

--[[ Parse the output of `dbus-send --print-reply … GetManagedObjects`.
Returns: { adapters = { {path, powered, address} }, devices = { {path, address, name, paired, trusted,
connected, blocked, uuids = {…}, icon, hid} } } ]]
function Z.parseObjects(text)
    local res = { adapters = {}, devices = {} }
    -- one chunk per object
    local starts = {}
    for pos, path in text:gmatch('()object path "([^"]+)"') do
        starts[#starts + 1] = { pos = pos, path = path }
    end
    for i, s in ipairs(starts) do
        local chunk = text:sub(s.pos, (starts[i + 1] and starts[i + 1].pos or #text + 1) - 1)
        local function prop(name)
            local typ, val = chunk:match('string "' .. name .. '"%s*variant%s+(%w+)%s+([^\n]*)')
            if not typ then return nil end
            if typ == "boolean" then return val:match("^true") ~= nil end
            if typ == "string" or typ == "object" then return val:match('"(.*)"') end
            return tonumber(val:match("^(%-?%d+)"))
        end
        if chunk:find('string "org.bluez.Adapter1"', 1, true) then
            res.adapters[#res.adapters + 1] = { path = s.path, powered = prop("Powered"), address = prop("Address") }
        elseif chunk:find('string "org.bluez.Device1"', 1, true) then
            local uuids, hid = {}, false
            local list = chunk:match('string "UUIDs"%s*variant%s+array %[(.-)%]')
            if list then
                for u in list:gmatch('string "([%x%-]+)"') do
                    u = u:lower()
                    uuids[#uuids + 1] = u
                    if HID_UUIDS[u] then hid = true end
                end
            end
            local icon = prop("Icon")
            res.devices[#res.devices + 1] = {
                path = s.path,
                address = prop("Address"),
                name = prop("Alias") or prop("Name") or prop("Address"),
                paired = prop("Paired") == true,
                trusted = prop("Trusted") == true,
                connected = prop("Connected") == true,
                blocked = prop("Blocked") == true,
                icon = icon,
                uuids = uuids,
                hid = hid or (icon ~= nil and icon:match("^input%-") ~= nil),
            }
        end
    end
    return res
end

-- Devices to connect automatically: paired, not blocked, input device
function Z.wanted(dev)
    return dev.hid and dev.paired and not dev.blocked
end

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end
Z.shq = shq

function Z.listCommand()
    return Z.DBUS_SEND .. " --system --print-reply --dest=org.bluez / org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null"
end

-- Connect in the background; the next query shows the result (Connected)
function Z.connectCommand(path, timeout_s)
    return ("%s --system --print-reply --reply-timeout=%d --dest=org.bluez %s org.bluez.Device1.Connect >/dev/null 2>&1 &")
        :format(Z.DBUS_SEND, (timeout_s or 30) * 1000, shq(path))
end

function Z.query()
    local p = io.popen(Z.listCommand(), "r")
    if not p then return nil end
    local out = p:read("*a")
    p:close()
    if not out or out == "" then return nil end
    return Z.parseObjects(out)
end

function Z.connect(path, timeout_s)
    os.execute(Z.connectCommand(path, timeout_s))
end

return Z
