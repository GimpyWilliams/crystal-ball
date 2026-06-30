-- medical_intel.lua
--
-- READ-ONLY fortress intelligence for the hospital / medical subsystem.
-- Mutates NOTHING. Shared helpers (section, is_available, world, report,
-- finish...) come from scripts/_prelude.lua, prepended by intel.py.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end

local function units_of(tname)
    local v = world.items.other[tname]
    local total, free = 0, 0
    if v then
        for _, it in ipairs(v) do
            total = total + it.stack_size
            if is_available(it) then free = free + it.stack_size end
        end
    end
    return { total_units = total, free_units = free }
end

-- 1. Hospitals defined (where the wounded are treated and supplies kept). In
-- DF50 a hospital is a LOCATION (abstract_building_hospitalst) on the fort site,
-- NOT a civzone -- see fort_locations() in _prelude.lua. No inner error-swallowing
-- pcall here: if the read ever fails, section() surfaces it under report.errors.
section('hospitals', function()
    report.hospitals = count_locations(function(ab)
        return df.abstract_building_hospitalst:is_instance(ab)
    end)
end)

-- 2. Patients: citizens flagged as needing healthcare (wounded/sick).
section('patients', function()
    local wounded = 0
    for _, u in ipairs(world.units.active) do
        pcall(function()
            if dfhack.units.isCitizen(u) and u.health
                    and u.health.flags.needs_healthcare then
                wounded = wounded + 1
            end
        end)
    end
    report.wounded = wounded
end)

-- 3. Caregiver coverage: how many citizens have each medical labor enabled.
local DOC_LABORS = {
    diagnose = 'DIAGNOSE', surgery = 'SURGERY', bone_setting = 'BONE_SETTING',
    suturing = 'SUTURING', dressing_wounds = 'DRESSING_WOUNDS',
}
section('caregivers', function()
    local counts = {}
    for key, lname in pairs(DOC_LABORS) do counts[key] = 0 end
    for _, u in ipairs(world.units.active) do
        pcall(function()
            if dfhack.units.isCitizen(u) then
                for key, lname in pairs(DOC_LABORS) do
                    if u.status.labors[df.unit_labor[lname]] then
                        counts[key] = counts[key] + 1
                    end
                end
            end
        end)
    end
    report.caregivers = counts
end)

-- 4. Medical supplies on hand (fort-wide). Soap is not a distinct item type in
-- this version, so it is omitted.
section('supplies', function()
    report.supplies = {
        cloth = units_of('CLOTH'), thread = units_of('THREAD'),
        crutches = units_of('CRUTCH'), splints = units_of('SPLINT'),
        buckets = units_of('BUCKET'),
    }
end)

finish()
