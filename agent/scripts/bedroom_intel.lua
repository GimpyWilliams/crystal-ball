-- bedroom_intel.lua
--
-- READ-ONLY mapping of every placed bed to its assigned citizen.
-- Identifies unowned beds and citizens lacking any bed assignment.
-- Mutates NOTHING.
--
-- In DF50+ ownership is tracked via u.owned_buildings on each unit (a vector
-- of building IDs). We invert that into a building_id->citizen map, then join
-- it against bedroom civzones by zone.id. The bed building's owner_id field
-- is always -1 in DF50+ and must not be used.
--
-- IMPORTANT: u.owned_buildings elements are DFHack int32_t userdata wrappers,
-- not native Lua numbers. tonumber() must be applied on both the map key and
-- the lookup to avoid silent type mismatches.
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

local function is_citizen(u)
    local ok = false
    pcall(function()
        ok = (dfhack.units.isCitizen(u) or dfhack.units.isResident(u))
             and dfhack.units.isActive(u)
    end)
    return ok
end

-- Index all citizens by id
local citizens_by_id = {}
local citizen_list = {}
local ok, err = pcall(function()
    for _, u in ipairs(df.global.world.units.active) do
        if is_citizen(u) then
            local name = unit_name(u)
            citizens_by_id[u.id] = name
            citizen_list[#citizen_list + 1] = { id = u.id, name = name }
        end
    end
end)
if not ok then
    report.errors[#report.errors + 1] = 'citizens: ' .. tostring(err)
end

-- Build building_id (Lua number) -> citizen_id map from u.owned_buildings.
-- The vector holds building references (userdata), not integer IDs, so we
-- extract the ID via bref.id and normalize with tonumber().
local citizen_of_building = {}
local ok2, err2 = pcall(function()
    for _, u in ipairs(df.global.world.units.active) do
        if is_citizen(u) and u.owned_buildings then
            local uid = u.id
            for _, bref in ipairs(u.owned_buildings) do
                pcall(function()
                    local bid = tonumber(bref.id)
                    if bid then citizen_of_building[bid] = uid end
                end)
            end
        end
    end
end)
if not ok2 then
    report.errors[#report.errors + 1] = 'owned_buildings: ' .. tostring(err2)
end

-- Count physical bed buildings for totals.
local bed_count = 0
local ok3a, err3a = pcall(function()
    for _, b in ipairs(df.global.world.buildings.all) do
        local btype
        pcall(function() btype = b:getType() end)
        if btype == df.building_type.Bed then
            bed_count = bed_count + 1
        end
    end
end)
if not ok3a then
    report.errors[#report.errors + 1] = 'bed_count: ' .. tostring(err3a)
end

-- Scan bedroom civzones; resolve owner by joining on tonumber(zone.id).
local beds = {}
local citizens_with_beds = {}
local ok3, err3 = pcall(function()
    for _, b in ipairs(df.global.world.buildings.all) do
        if df.building_civzonest:is_instance(b)
                and b.type == df.civzone_type.Bedroom then
            local owner_id, owner_name
            pcall(function()
                local cid = citizen_of_building[tonumber(b.id)]
                if cid then
                    owner_id = cid
                    owner_name = citizens_by_id[cid]
                    citizens_with_beds[cid] = true
                end
            end)
            beds[#beds + 1] = {
                pos = { x = b.x1, y = b.y1, z = b.z },
                owner_id = owner_id,
                owner_name = owner_name,
            }
        end
    end
end)
if not ok3 then
    report.errors[#report.errors + 1] = 'bedroom_zones: ' .. tostring(err3)
end

-- Citizens with no assigned bed
local unhoused = {}
for _, c in ipairs(citizen_list) do
    if not citizens_with_beds[c.id] then
        unhoused[#unhoused + 1] = c
    end
end

local unowned_count = 0
for _, bed in ipairs(beds) do
    if not bed.owner_id then unowned_count = unowned_count + 1 end
end

report.total_citizens = #citizen_list
report.total_beds = bed_count
report.total_bedroom_zones = #beds
report.unowned_beds = unowned_count
report.beds = beds
report.citizens_without_beds = unhoused
print(json.encode(report))
