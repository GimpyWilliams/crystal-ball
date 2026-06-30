-- building_config.lua
--
-- READ-ONLY. Report ZONE/ROOM ASSIGNMENTS: which civzones (bedrooms, offices,
-- dining halls, tombs, pastures, ...) are assigned to a specific unit, and a
-- by-type tally of assigned vs unassigned. In DF v50 a room's owner is NOT a
-- field on the furniture (building_bedst has no .owner); ownership lives on the
-- civzone as assigned_unit_id. This generalizes the bedroom-only view to every
-- assignable zone type. Mutates NOTHING.
--
-- Best-effort throughout (per-field pcall): a struct change degrades one row to
-- an omission, never a broken report.
--
-- Shared helpers (section, world, report, finish, fort_loaded) come from
-- scripts/_prelude.lua, prepended by intel.py.
--
-- Run via: RunCommand("lua", [<prelude + this file>]).

if not report.fort_loaded then finish() return end

local assignments = {}        -- zones with an assigned unit
local by_type = {}            -- zone_type -> {assigned, unassigned}

local function bump(ztype, assigned)
    local t = by_type[ztype]
    if not t then t = { assigned = 0, unassigned = 0 }; by_type[ztype] = t end
    if assigned then t.assigned = t.assigned + 1 else t.unassigned = t.unassigned + 1 end
end

for _, b in ipairs(world.buildings.all) do
    if df.building_civzonest:is_instance(b) then
        pcall(function()
            local ztype = tostring(df.civzone_type[b.type] or b.type)
            local uid = -1
            pcall(function() uid = b.assigned_unit_id end)
            local assigned = (uid ~= nil and uid >= 0)
            bump(ztype, assigned)
            if assigned then
                local rec = { zone_type = ztype, unit_id = uid }
                pcall(function() rec.pos = { x = b.x1, y = b.y1, z = b.z } end)
                pcall(function()
                    local u = df.unit.find(uid)
                    if u then rec.unit = dfhack.units.getReadableName(u) end
                end)
                assignments[#assignments + 1] = rec
            end
        end)
    end
end

report.assignments = assignments
report.by_type = by_type
finish()
