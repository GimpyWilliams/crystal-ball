-- hotkeys_intel.lua
--
-- READ-ONLY intel for F-key map bookmarks (df.global.plotinfo.main.hotkeys).
-- Returns all 16 slots: key label (F1-F16), name, coordinates, and whether
-- the slot is active (cmd == 0). Inactive slots have name="" and active=false.
-- Shared helpers (section, report, finish, world...) from scripts/_prelude.lua.
--
-- Run via: RunCommand("lua", [<prelude + this file>]).

if not report.fort_loaded then finish() return end

section('hotkeys', function()
    local out = {}
    local slots = df.global.plotinfo.main.hotkeys
    for i = 0, 15 do
        local h = slots[i]
        out[#out + 1] = {
            key    = 'F' .. (i + 1),
            name   = tostring(h.name),
            x      = h.x,
            y      = h.y,
            z      = h.z,
            active = (h.cmd == 0),
        }
    end
    report.hotkeys = out
end)

finish()
