-- zones_intel.lua
--
-- READ-ONLY fortress intelligence for ZONES & LOCATIONS. Mutates NOTHING.
-- Two distinct things in DF50:
--   * Locations (abstract_building_*st on the fort site): taverns, temples,
--     hospitals, libraries, guildhalls -- the named, managed rooms. A hospital
--     is one of THESE, not a civzone (see _prelude.lua fort_locations()).
--   * Civzones (building_civzonest in world.buildings.all): the raw zone
--     rectangles (bedrooms, dining halls, pastures, ...). Reported as a count
--     by type, since there are usually many.
-- Shared helpers (section, fort_locations, location_name, world, report,
-- finish...) come from scripts/_prelude.lua, prepended by intel.py.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end

-- Short class label for a location, e.g. "hospital" from
-- "<type: abstract_building_hospitalst>".
local function loc_type(ab)
    local t = tostring(ab._type)
    return (t:gsub('.*abstract_building_', ''):gsub('st>?$', ''):gsub('>$', ''))
end

-- DF stores some hospital supplies in internal "dimension" units, not whole
-- items: the in-game hospital screen divides by these before displaying (e.g.
-- desired_thread 150000 shows as 10). Mirror that conversion so this report
-- matches what the player sees. Items not listed here are discrete (1:1):
-- splints, crutches, buckets.
local SUPPLY_DIMENSION = {
    thread = 15000, cloth = 10000, powder = 150, soap = 150,
}

-- Convert a raw dimension count to whole items for the given supply key.
local function to_items(key, raw)
    local d = SUPPLY_DIMENSION[key] or 1
    return math.floor((raw or 0) / d)
end

-- 1. Locations on the fort site, with hospital supply detail where present.
section('locations', function()
    local out = {}
    for _, ab in ipairs(fort_locations()) do
        local rec = { type = loc_type(ab), name = location_name(ab) }
        if df.abstract_building_hospitalst:is_instance(ab) then
            local c = ab.contents
            -- desired_* are the player-set maximums; count_* what's stocked now.
            -- Both are raw dimension units; to_items() converts to whole items so
            -- the report matches the in-game hospital screen.
            rec.hospital = {
                splints  = { have = to_items('splints',  c.count_splints),  max = to_items('splints',  c.desired_splints) },
                thread   = { have = to_items('thread',   c.count_thread),   max = to_items('thread',   c.desired_thread) },
                cloth    = { have = to_items('cloth',    c.count_cloth),    max = to_items('cloth',    c.desired_cloth) },
                crutches = { have = to_items('crutches', c.count_crutches), max = to_items('crutches', c.desired_crutches) },
                powder   = { have = to_items('powder',   c.count_powder),   max = to_items('powder',   c.desired_powder) },
                buckets  = { have = to_items('buckets',  c.count_buckets),  max = to_items('buckets',  c.desired_buckets) },
                soap     = { have = to_items('soap',     c.count_soap),     max = to_items('soap',     c.desired_soap) },
            }
        end
        out[#out + 1] = rec
    end
    report.locations = out
end)

-- 2. Civzones (raw zone rectangles), counted by type for a quick overview.
section('civzones', function()
    local by_type, total = {}, 0
    for _, b in ipairs(world.buildings.all) do
        if df.building_civzonest:is_instance(b) then
            total = total + 1
            local tname = tostring(df.civzone_type[b.type] or b.type)
            by_type[tname] = (by_type[tname] or 0) + 1
        end
    end
    report.civzones = { total = total, by_type = by_type }
end)

finish()
