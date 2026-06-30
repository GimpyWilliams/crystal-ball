-- building_locate.lua
--
-- READ-ONLY. Find every BUILDING of a given type and report each instance's
-- position, build stage, and (for workshops/furnaces) whether it is busy and
-- what it is working on. This is the building-side counterpart to
-- stockpile_locate: it answers "where are my levers / floodgates / bridges /
-- wells / altars / nest boxes / a specific workshop?", which no other tool does
-- (shops_and_orders only counts workshops by type, with no positions).
-- Mutates NOTHING.
--
-- An optional second arg is a SUBTYPE index (resolve.py turns "Smelter" into
-- Furnace + subtype, "Lever" into Trap + subtype, "Masons" into Workshop +
-- subtype): when given, only that subtype is matched.
--
-- Performance: iterates world.buildings.all (cheap) and reads each building's
-- own fields -- it never calls dfhack.buildings.findAtTile per item, which would
-- poison the single-threaded RPC (see acquirable_items.lua).
--
-- Args: building_type_name (e.g. "Workshop", "Trap", "NestBox"), [subtype_index]
-- Run via: RunCommand("lua", [<prelude + this file>, "Furnace", "1"])

if not report.fort_loaded then finish() return end

local want_type = select(1, ...) or ''
if want_type == '' then
    report.error = 'building_type argument required (e.g. "Workshop", "Trap")'
    finish(); return
end

local subtype_arg = select(2, ...)
local want_subtype = nil
if subtype_arg ~= nil and subtype_arg ~= '' then
    want_subtype = tonumber(subtype_arg)
end

report.building_type = want_type
report.subtype = want_subtype

-- The subtype enum that lives under a given parent building_type, for decoding a
-- subtype index back to a readable name (Workshop->workshop_type, etc.).
local function subtype_enum(type_name)
    if type_name == 'Workshop' then return df.workshop_type end
    if type_name == 'Furnace'  then return df.furnace_type  end
    if type_name == 'Trap'     then return df.trap_type     end
    if type_name == 'Civzone'  then return df.civzone_type  end
    return nil
end

local DETAIL_CAP = 300
local items = {}
local total, built_count, busy_count = 0, 0, 0
local by_subtype = {}   -- subtype-name -> count (for the summary tier)

for _, b in ipairs(world.buildings.all) do
    pcall(function()
        local tname = df.building_type[b:getType()] or tostring(b:getType())
        if tname ~= want_type then return end

        local sub = -1
        pcall(function() sub = b:getSubtype() end)
        if want_subtype ~= nil and sub ~= want_subtype then return end

        total = total + 1

        -- Readable subtype name (workshop/furnace/trap/civzone), else nil.
        local subname = nil
        local enum = subtype_enum(tname)
        if enum and sub and sub >= 0 then
            pcall(function() subname = enum[sub] end)
        end

        -- Build stage: a building under construction has stage < max.
        local built = true
        pcall(function()
            built = (b:getBuildStage() >= b:getMaxBuildStage())
        end)
        if built then built_count = built_count + 1 end

        -- Jobs: #jobs>0 means a job is queued/running at this building.
        local njobs = 0
        pcall(function() njobs = #b.jobs end)
        local busy = njobs > 0
        if busy then busy_count = busy_count + 1 end
        local cur_job = nil
        pcall(function()
            if njobs > 0 then cur_job = df.job_type[b.jobs[0].job_type] end
        end)

        local key = subname or tname
        by_subtype[key] = (by_subtype[key] or 0) + 1

        if #items < DETAIL_CAP then
            items[#items + 1] = {
                pos = { x = b.x1, y = b.y1, z = b.z },
                subtype = subname,
                built = built,
                busy = busy,
                job = cur_job,
            }
        end
    end)
end

report.total        = total
report.built        = built_count
report.busy         = busy_count
report.items        = items
report.items_capped = (#items >= DETAIL_CAP)
report.by_subtype   = by_subtype
finish()
