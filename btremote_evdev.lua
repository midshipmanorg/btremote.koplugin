--[[ Find Bluetooth input devices under /dev/input and read them directly.

On PocketBook, KOReader usually does not read input devices itself but gets everything through
InkView. Where the plugin may open the device nodes (KOReader running as root, or a firmware that
makes them readable), this module looks in /sys/class/input for devices on bus 0005 (Bluetooth),
opens their eventN non-blocking, optionally grabs them (EVIOCGRAB, so the firmware no longer sees
the buttons) and returns their EV_KEY events. On the PocketBook Era the nodes belong to root and
KOReader runs as `reader`, so this path reports "no access" and buttons arrive via InkView.
Also runs without KOReader (tests): if KOReader's ffi headers are missing, the needed parts are
declared here.
]]

local ffi = require("ffi")
local bit = require("bit")
local C = ffi.C

if not pcall(require, "ffi/posix_h") then
    ffi.cdef[[
    struct timeval { long tv_sec; long tv_usec; };
    int open(const char *, int, ...);
    int close(int);
    long read(int, void *, size_t);
    int ioctl(int, unsigned long, ...);
    ]]
end
if not pcall(require, "ffi/linux_input_h") then
    ffi.cdef[[
    struct input_event { struct timeval time; uint16_t type; uint16_t code; int32_t value; };
    ]]
end

local E = {}

E.BUS_BLUETOOTH = 0x0005
E.EV_KEY = 1
local O_RDONLY, O_NONBLOCK, O_CLOEXEC = 0, 2048, 524288
local EAGAIN, EINTR, EACCES, EPERM = 11, 4, 13, 1
-- _IOW('E', 0x90, int)
local EVIOCGRAB = 0x40044590

-- paths can be redirected for tests
E.sysfs = "/sys/class/input"
E.devdir = "/dev/input"

local function readLine(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    return s
end

local function hasKeys(cap)
    -- capabilities/key: hex words, "0" = no keys
    return cap ~= nil and cap:match("[1-9a-fA-F]") ~= nil
end

local function listDir(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then ok, lfs = pcall(require, "lfs") end
    local out = {}
    if ok then
        local okd, iter, state = pcall(lfs.dir, path)
        if not okd then return out end
        for name in iter, state do out[#out + 1] = name end
    else
        local p = io.popen('ls -1 "' .. path .. '" 2>/dev/null')
        if p then
            for name in p:lines() do out[#out + 1] = name end
            p:close()
        end
    end
    return out
end

--[[ All Bluetooth input devices with keys: { {node="event5", path="/dev/input/event5",
name="…", uniq="aa:bb:…"}, … } sorted by number. ]]
function E.scan()
    local found = {}
    for _, node in ipairs(listDir(E.sysfs)) do
        local n = node:match("^event(%d+)$")
        if n then
            local base = E.sysfs .. "/" .. node .. "/device"
            local bus = tonumber(readLine(base .. "/id/bustype") or "", 16)
            if bus == E.BUS_BLUETOOTH and hasKeys(readLine(base .. "/capabilities/key")) then
                found[#found + 1] = {
                    node = node,
                    num = tonumber(n),
                    path = E.devdir .. "/" .. node,
                    name = readLine(base .. "/name") or node,
                    uniq = readLine(base .. "/uniq") or "",
                }
            end
        end
    end
    table.sort(found, function(a, b) return a.num < b.num end)
    return found
end

-- Open; returns fd, or nil and a status ("no access", …)
function E.open(path)
    local fd = C.open(path, bit.bor(O_RDONLY, O_NONBLOCK, O_CLOEXEC))
    if fd < 0 then
        local err = ffi.errno()
        if err == EACCES or err == EPERM then return nil, "no access" end
        return nil, "error " .. err
    end
    return fd
end

function E.grab(fd, on)
    return C.ioctl(fd, EVIOCGRAB, ffi.cast("int", on and 1 or 0)) == 0
end

function E.close(fd)
    C.close(fd)
end

local evbuf = ffi.new("struct input_event[16]")
local evsize = ffi.sizeof("struct input_event")

--[[ Read everything pending. Returns: list of EV_KEY events
{type, code, value, time={sec,usec}}, and whether the device is gone (ENODEV/end of file). ]]
function E.read(fd)
    local out
    while true do
        local n = tonumber(C.read(fd, evbuf, ffi.sizeof(evbuf)))
        if n < 0 then
            local err = ffi.errno()
            if err == EAGAIN or err == EINTR then return out, false end
            return out, true -- ENODEV (disconnected) and anything else: close, rescan
        elseif n == 0 then
            return out, true
        end
        for i = 0, math.floor(n / evsize) - 1 do
            local ev = evbuf[i]
            if ev.type == E.EV_KEY then
                out = out or {}
                out[#out + 1] = {
                    type = E.EV_KEY,
                    code = ev.code,
                    value = ev.value,
                    time = { sec = tonumber(ev.time.tv_sec), usec = tonumber(ev.time.tv_usec) },
                }
            end
        end
    end
end

return E
