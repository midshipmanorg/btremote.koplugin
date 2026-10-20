--[[ Translations for the plugin's own strings.

KOReader only loads translations for its own text domain, not for plugins. This wrapper looks up
the plugin's strings in a small built-in table for the current UI language and falls back to
KOReader's gettext (which still translates strings KOReader itself knows).
To add a language, add a table below keyed by the language prefix of `gettext.current_lang`.
]]

local gettext = require("gettext")

local catalogs = {
    de = {
        ["Bluetooth remote"] = "Bluetooth-Fernbedienung",
        ["Use remote"] = "Fernbedienung verwenden",
        ["Devices"] = "Geräte",
        ["Connect automatically"] = "Automatisch verbinden",
        ["Reconnects paired remotes by itself after power-on and wake-up (the firmware does not): every 10 s for 3 minutes, then every 2 minutes. If the remote is asleep, press a button."] =
            "Verbindet gekoppelte Fernbedienungen nach dem Einschalten und Aufwachen selbst (die Firmware tut es nicht): 3 Minuten lang alle 10 s, danach alle 2 Minuten. Schläft die Fernbedienung, eine Taste drücken.",
        ["Connect now"] = "Jetzt verbinden",
        ["Connecting… If the remote is asleep, press a button."] = "Verbinde … Falls die Fernbedienung schläft, eine Taste drücken.",
        ["Grab buttons exclusively"] = "Tasten exklusiv übernehmen",
        ["The firmware no longer sees the remote's buttons (no double actions, no volume popup). Only while KOReader is in the foreground."] =
            "Die Firmware sieht die Tasten der Fernbedienung dann nicht mehr (keine doppelten Aktionen, keine Lautstärkeanzeige). Gilt nur, solange KOReader im Vordergrund ist.",
        ["Learn new button…"] = "Neue Taste anlernen …",
        ["Button mapping"] = "Tastenbelegung",
        ["Restore default mapping"] = "Standardbelegung wiederherstellen",
        ["Long-press duration: %1 ms"] = "Dauer für langes Drücken: %1 ms",
        ["Long press after"] = "Langes Drücken ab",
        ["Key log"] = "Tastenprotokoll",
        ["Shows the last buttons with code and source – useful when a button does nothing."] =
            "Zeigt die letzten Tasten mit Code und Herkunft – hilfreich, wenn eine Taste nichts tut.",
        ["No button received yet. Press a button, then open this again."] =
            "Noch keine Taste angekommen. Taste drücken, dann hier erneut öffnen.",
        ["nothing"] = "nichts",
        [" · long: %1"] = " · lang: %1",
        ["Short press: %1"] = "Kurz drücken: %1",
        ["Long press: %1"] = "Lang drücken: %1",
        ["Remove button"] = "Taste entfernen",
        ["Press the button on the remote now…"] = "Jetzt die Taste auf der Fernbedienung drücken …",
        ["%1 (code %2, %3)%4"] = "%1 (Code %2, %3)%4",
        ["read directly"] = "direkt gelesen",
        ["via InkView"] = "über InkView",
        ["currently: %1"] = "bisher: %1",
        ["Next page"] = "Vorblättern",
        ["Previous page"] = "Zurückblättern",
        ["Next chapter"] = "Nächstes Kapitel",
        ["Previous chapter"] = "Voriges Kapitel",
        ["Decide later"] = "Später festlegen",
        ["direct"] = "direkt",
        ["mapped"] = "belegt",
        ["passed on"] = "weitergereicht",
        ["connected"] = "verbunden",
        ["disconnected"] = "getrennt",
        ["connects automatically"] = "verbindet automatisch",
        ["Untick to neither connect nor use this device (e.g. a keyboard for typing)."] =
            "Haken entfernen, um dieses Gerät weder zu verbinden noch zu verwenden (etwa eine Tastatur zum Tippen).",
        ["BlueZ not reachable (Bluetooth off?)"] = "BlueZ nicht erreichbar (Bluetooth aus?)",
        ["No paired remote. Pair it in the PocketBook settings under Bluetooth."] =
            "Keine gekoppelte Fernbedienung. Koppeln in den PocketBook-Einstellungen unter Bluetooth.",
        ["No Bluetooth input devices found."] = "Keine Bluetooth-Eingabegeräte gefunden.",
        -- device states
        ["ignored"] = "ignoriert",
        ["off"] = "aus",
        ["open, exclusive"] = "verbunden, exklusiv",
        ["open"] = "verbunden",
        ["no access"] = "kein Zugriff",
        -- key names (btremote_keys.names)
        ["Enter"] = "Enter",
        ["Backspace"] = "Rücktaste",
        ["Space"] = "Leertaste",
        ["Home"] = "Pos1",
        ["Up"] = "Pfeil hoch",
        ["Page up"] = "Bild hoch",
        ["Left"] = "Pfeil links",
        ["Right"] = "Pfeil rechts",
        ["End"] = "Ende",
        ["Down"] = "Pfeil runter",
        ["Page down"] = "Bild runter",
        ["Mute"] = "Stumm",
        ["Volume down"] = "Leiser",
        ["Volume up"] = "Lauter",
        ["Power"] = "Ein/Aus",
        ["Menu"] = "Menü",
        ["Back"] = "Zurück",
        ["Forward"] = "Vorwärts",
        ["Next track"] = "Nächster Titel",
        ["Play/pause"] = "Wiedergabe/Pause",
        ["Previous track"] = "Voriger Titel",
        ["Stop"] = "Stopp",
        ["Rewind"] = "Rückspulen",
        ["Homepage"] = "Startseite",
        ["Play"] = "Wiedergabe",
        ["Pause"] = "Pause",
        ["Fast forward"] = "Vorspulen",
        ["Mouse left"] = "Maus links",
        ["Mouse right"] = "Maus rechts",
        ["Mouse middle"] = "Maus Mitte",
        ["Button A"] = "Knopf A",
        ["Button B"] = "Knopf B",
        ["Button X"] = "Knopf X",
        ["Button Y"] = "Knopf Y",
        ["Left shoulder"] = "Schulter links",
        ["Right shoulder"] = "Schulter rechts",
        ["Next"] = "Weiter",
        ["Previous"] = "Zurück",
        ["D-pad up"] = "Steuerkreuz hoch",
        ["D-pad down"] = "Steuerkreuz runter",
        ["D-pad left"] = "Steuerkreuz links",
        ["D-pad right"] = "Steuerkreuz rechts",
        ["InkView key %1"] = "InkView-Taste %1",
        ["Key %1"] = "Taste %1",
        -- _meta.lua
        ["Page-turner remotes and other Bluetooth buttons on PocketBook: connects paired remotes automatically, short/long press mapping per button."] =
            "Blätter-Fernbedienungen und andere Bluetooth-Tasten auf PocketBook: verbindet gekoppelte Fernbedienungen automatisch, Belegung je Taste kurz/lang.",
    },
}

local function translate(msgid)
    local lang = gettext.current_lang or "C"
    local cat = catalogs[lang:match("^(%a%a)")]
    local s = cat and cat[msgid]
    if s then return s end
    return gettext(msgid)
end

return translate
