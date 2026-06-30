-- diagnose_medical.lua
--
-- READ-ONLY root-cause analysis for "can my wounded actually be treated?".
-- Checks for a hospital zone, caregiver coverage, and basic supplies, and
-- surfaces the wounded count as context. Mutates NOTHING. Shared helpers come
-- from scripts/_prelude.lua.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end
report.target = 'treated patients'
report.facts = {}

local function free_units(tname)
    local v = world.items.other[tname]
    local total = 0
    if v then
        for _, it in ipairs(v) do
            if is_available(it) then total = total + it.stack_size end
        end
    end
    return total
end

-- Wounded count (context for whether any of this is urgent).
local wounded = 0
pcall(function()
    for _, u in ipairs(world.units.active) do
        if dfhack.units.isCitizen(u) and u.health
                and u.health.flags.needs_healthcare then
            wounded = wounded + 1
        end
    end
end)
report.facts.wounded = wounded
add('wounded_present', wounded == 0, 'info',
    wounded .. ' citizen(s) currently need healthcare')

-- 1. Is there a hospital? In DF50 a hospital is a LOCATION
-- (abstract_building_hospitalst) on the fort site, NOT a civzone -- see
-- fort_locations() in _prelude.lua. The outer pcall keeps a future API change
-- from breaking the whole diagnosis; it no longer hides a per-zone field error.
local hospitals = 0
pcall(function()
    hospitals = count_locations(function(ab)
        return df.abstract_building_hospitalst:is_instance(ab)
    end)
end)
report.facts.hospitals = hospitals
add('hospital_exists', hospitals > 0, 'blocker', hospitals .. ' hospital(s) defined')

-- Count citizens with a given labor ENABLED. Unlike most labors, the medical
-- ones are off by default and turned on per-dwarf, so the work-detail model
-- ("anyone can") doesn't apply -- we count actual enabled caregivers.
local function caregivers_with(labor_name)
    local n = 0
    pcall(function()
        local lab = df.unit_labor[labor_name]
        for _, u in ipairs(world.units.active) do
            pcall(function()
                if dfhack.units.isCitizen(u) and u.status.labors[lab] then
                    n = n + 1
                end
            end)
        end
    end)
    return n
end

-- 2. Is anyone able to diagnose? Without a diagnostician, nothing else proceeds.
local diagnosticians = caregivers_with('DIAGNOSE')
report.facts.diagnosticians = diagnosticians
add('diagnostician_assigned', diagnosticians > 0, 'blocker',
    diagnosticians .. ' citizen(s) have the diagnosis labor enabled')

-- 3. Treatment labors (surgery / bone-setting / suturing / dressing). Info: a
-- gap only bites if a wound needs that specific treatment.
for _, pair in ipairs({
    { 'surgeon', 'SURGERY' }, { 'bone_doctor', 'BONE_SETTING' },
    { 'suturer', 'SUTURING' }, { 'wound_dresser', 'DRESSING_WOUNDS' },
}) do
    local n = caregivers_with(pair[2])
    add(pair[1], n > 0, 'info', pair[2] .. ': ' .. n .. ' caregiver(s) enabled')
end

-- 4. Basic supplies (info): splints/crutches for fractures, cloth/thread for
-- dressing, buckets for water.
report.facts.crutches = free_units('CRUTCH')
report.facts.splints = free_units('SPLINT')
report.facts.cloth = free_units('CLOTH')
report.facts.buckets = free_units('BUCKET')
add('supplies_on_hand', (report.facts.crutches + report.facts.splints
    + report.facts.cloth) > 0, 'info',
    report.facts.splints .. ' splint(s), ' .. report.facts.crutches
    .. ' crutch(es), ' .. report.facts.cloth .. ' cloth, '
    .. report.facts.buckets .. ' bucket(s)')

finish()
