--[[ Button logic of the Bluetooth remote, without KOReader dependencies (testable with plain luajit).

Mapping: `buttons["<code>"] = { short = <Dispatcher actions>, long = <Dispatcher actions> }`.
The code is the EV_KEY code as Input:handleKeyBoardEv sees it: Linux key codes from reading
/dev/input directly (and from InkView's EVT_KEYPRESS_EXT); negative values are InkView keys
(EVT_KEYPRESS, -IV_KEY_*).
Without a long-press mapping the action fires on key down (no delay), otherwise on release or
after `long_ms` held.
]]

local K = {}

-- Linux key codes remotes typically send (input-event-codes.h); English names, translated in the UI
K.names = {
    [1] = "Esc", [14] = "Backspace", [15] = "Tab", [28] = "Enter", [57] = "Space",
    [102] = "Home", [103] = "Up", [104] = "Page up", [105] = "Left",
    [106] = "Right", [107] = "End", [108] = "Down", [109] = "Page down",
    [113] = "Mute", [114] = "Volume down", [115] = "Volume up", [116] = "Power", [139] = "Menu",
    [158] = "Back", [159] = "Forward", [163] = "Next track", [164] = "Play/pause",
    [165] = "Previous track", [166] = "Stop", [168] = "Rewind", [172] = "Homepage",
    [200] = "Play", [201] = "Pause", [207] = "Play", [208] = "Fast forward",
    [272] = "Mouse left", [273] = "Mouse right", [274] = "Mouse middle",
    [304] = "Button A", [305] = "Button B", [307] = "Button X", [308] = "Button Y",
    [310] = "Left shoulder", [311] = "Right shoulder", [314] = "Select", [315] = "Start",
    [407] = "Next", [412] = "Previous", [544] = "D-pad up", [545] = "D-pad down",
    [546] = "D-pad left", [547] = "D-pad right",
}

-- Name of a key code; `tr` translates (default: none), templates use %1 like KOReader's T()
function K.keyName(code, tr)
    tr = tr or function(s) return s end
    code = tonumber(code)
    local n = K.names[code]
    if n then return tr(n) end
    if code and code < 0 then return (tr("InkView key %1"):gsub("%%1", tostring(-code))) end
    return (tr("Key %1"):gsub("%%1", tostring(code)))
end

-- Touchscreen and stylus codes (BTN_TOOL_*, BTN_TOUCH …) – never learn these as remote buttons
function K.isTouchCode(code)
    return code >= 0x140 and code <= 0x14f
end

local NEXT = { page_jmp = 1 }
local PREV = { page_jmp = -1 }
-- Common codes of page-turner remotes (keyboard, volume and media modes)
K.default_buttons = {
    ["109"] = { short = NEXT }, -- Page down
    ["106"] = { short = NEXT }, -- Right
    ["108"] = { short = NEXT }, -- Down
    ["114"] = { short = NEXT }, -- Volume down
    ["163"] = { short = NEXT }, -- Next track
    ["57"] = { short = NEXT },  -- Space
    ["104"] = { short = PREV }, -- Page up
    ["105"] = { short = PREV }, -- Left
    ["103"] = { short = PREV }, -- Up
    ["115"] = { short = PREV }, -- Volume up
    ["165"] = { short = PREV }, -- Previous track
}

local function copy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = copy(v) end
    return r
end
K.copy = copy

function K.defaultButtons()
    return copy(K.default_buttons)
end

-- Does a Dispatcher mapping contain at least one action? (`settings` is just metadata)
function K.hasActions(t)
    if type(t) ~= "table" then return false end
    for k in pairs(t) do
        if k ~= "settings" then return true end
    end
    return false
end

-- Drop the same key arriving via InkView shortly after reading it directly
K.DEDUPE_S = 0.3

--[[ State machine.
opts: now() → seconds, schedule(delay_s, fn) → handle, unschedule(handle),
      run(actions, code, long), buttons (table, read live), long_ms
]]
local Machine = {}
Machine.__index = Machine

function K.new(opts)
    local m = setmetatable({}, Machine)
    m.now = opts.now
    m.schedule = opts.schedule
    m.unschedule = opts.unschedule
    m.run = opts.run
    m.buttons = opts.buttons or {}
    m.long_ms = opts.long_ms or 600
    m.pressed = {}
    m.last_direct = {} -- [code] = time of the last directly read event
    m.learn_cb = nil
    m.learn_code = nil
    return m
end

-- Learning: the next pressed key goes to cb(code, direct) instead of the mapping
function Machine:learn(cb)
    self.learn_cb = cb
end

function Machine:cancelLearn()
    self.learn_cb = nil
end

function Machine:releaseAll()
    for code, p in pairs(self.pressed) do
        if p.timer then self.unschedule(p.timer) end
        self.pressed[code] = nil
    end
end

--[[ One EV_KEY event. value: 1 pressed, 0 released, 2 repeat.
direct: read from /dev/input by the plugin (otherwise via InkView/Input).
Returns true = consumed (do not pass on to KOReader). ]]
function Machine:feed(code, value, direct)
    local key = tostring(code)
    local t = self.now()
    if direct then
        self.last_direct[key] = t
    else
        local last = self.last_direct[key]
        if last and t - last < K.DEDUPE_S then
            return true
        end
    end

    if self.learn_cb and value == 1 and not K.isTouchCode(code) then
        local cb = self.learn_cb
        self.learn_cb = nil
        self.learn_code = key
        cb(code, direct)
        return true
    end
    if self.learn_code == key then
        -- also swallow repeats and the release of the learned key
        if value == 0 then self.learn_code = nil end
        return true
    end

    local btn = self.buttons[key]
    if not btn or not (K.hasActions(btn.short) or K.hasActions(btn.long)) then
        return false
    end

    if value == 1 then
        local old = self.pressed[key]
        if old and old.timer then self.unschedule(old.timer) end
        if K.hasActions(btn.long) then
            local p = { fired = false }
            p.timer = self.schedule(self.long_ms / 1000, function()
                p.timer = nil
                if self.pressed[key] == p then
                    p.fired = true
                    self.run(btn.long, code, true)
                end
            end)
            self.pressed[key] = p
        else
            self.pressed[key] = { fired = true }
            self.run(btn.short, code, false)
        end
    elseif value == 0 then
        local p = self.pressed[key]
        self.pressed[key] = nil
        if p and not p.fired then
            if p.timer then self.unschedule(p.timer) end
            if K.hasActions(btn.short) then
                self.run(btn.short, code, false)
            end
        end
    end
    -- value 2 (repeat): consumed, triggers nothing
    return true
end

return K
