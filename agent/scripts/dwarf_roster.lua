-- dwarf_roster.lua
--
-- READ-ONLY one-line-per-dwarf roster of fort citizens: name, profession,
-- what they're doing right now, stress, unmet-need count, wounded flag, and
-- any active strange mood. The at-a-glance "who's here and how are they" view.
-- Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

local json = require('json')

local report = { errors = {} }
report.fort_loaded = (df.global.world.map.block_index ~= nil)
if not report.fort_loaded then
    print(json.encode(report))
    return
end

local function unit_name(u)
    local n
    pcall(function() n = dfhack.units.getReadableName(u) end)
    if n and n ~= '' then return n end
    pcall(function() n = dfhack.TranslateName(dfhack.units.getVisibleName(u)) end)
    return (n and n ~= '') and n or ('unit#' .. u.id)
end

local function profession(u)
    local p
    pcall(function() p = dfhack.units.getProfessionName(u) end)
    return p or '?'
end

local function current_activity(u)
    local j = u.job.current_job
    if not j then return 'Idle' end
    return df.job_type[j.job_type] or ('job:' .. tostring(j.job_type))
end

local function stress_of(u)
    local s
    pcall(function() s = u.status.current_soul.personality.stress end)
    return s
end

local function unmet_needs(u)
    local c = 0
    pcall(function()
        for _, nd in ipairs(u.status.current_soul.personality.needs) do
            if nd.focus_level < 0 then c = c + 1 end
        end
    end)
    return c
end

local function is_citizen(u)
    local ok = false
    pcall(function()
        ok = (dfhack.units.isCitizen(u) or dfhack.units.isResident(u))
             and dfhack.units.isActive(u)
    end)
    return ok
end

local dwarves = {}
local ok, err = pcall(function()
    for _, u in ipairs(df.global.world.units.active) do
        if is_citizen(u) then
            local mood = 'none'
            if u.mood and u.mood >= 0 then
                mood = df.mood_type[u.mood] or tostring(u.mood)
            end
            local species = 'unknown'
            pcall(function()
                local r = df.global.world.raws.creatures.all[u.race]
                if r then species = r.creature_id end
            end)
            dwarves[#dwarves + 1] = {
                id = u.id,
                name = unit_name(u),
                profession = profession(u),
                activity = current_activity(u),
                stress = stress_of(u),
                unmet_needs = unmet_needs(u),
                wounded = (#u.body.wounds > 0),
                mood = mood,
                species = species,
            }
        end
    end
end)
if not ok then
    report.errors[#report.errors + 1] = 'roster: ' .. tostring(err)
end

report.count = #dwarves
report.dwarves = dwarves
print(json.encode(report))
