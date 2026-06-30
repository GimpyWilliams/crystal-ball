-- stockpile_locate.lua
--
-- READ-ONLY. Find every stockpile (or other location) holding items of the
-- given item type and report the count and stack units per location.
-- Groups results as: named/numbered stockpile, carried by a unit, inside a
-- non-stockpile building, or on open ground. Mutates NOTHING.
--
-- An optional second arg is a SUBTYPE index (resolve.py turns "nest box" into
-- TOOL + subtype 10): when given, only items of that subtype are counted, so a
-- query for one of the ~30 things that share item_type TOOL (nest box, jug,
-- wheelbarrow, book, altar...) returns just that thing instead of the whole pile.
--
-- Output for the formatter:
--   report.locations  named buckets (stockpile/building/unit) with counts+pos
--   report.ground     loose-on-ground scatter: by_z, top_tiles, counts
--   report.items      per-item detail [{pos={x,y,z}, where, n}], capped -- the
--                     formatter lists these when few (auto-tier) for exact coords
--
-- Args: item_type_name (e.g. "THREAD"), [subtype_index]
-- Run via: RunCommand("lua", [<prelude + this file>, "TOOL", "10"])

if not report.fort_loaded then finish() return end

local item_type_name = string.upper(select(1, ...) or '')
if item_type_name == '' then
    report.error = 'item_type_name argument required (e.g. "THREAD")'
    finish(); return
end

local subtype_arg = select(2, ...)
local want_subtype = nil
if subtype_arg ~= nil and subtype_arg ~= '' then
    want_subtype = tonumber(subtype_arg)
end

-- DFHack THROWS on an unknown world.items.other key -- it does NOT return nil --
-- so the lookup must be pcall-guarded. A plain `if not vec` can never catch a
-- bad type name (this was the NEST_BOX / BOOTS hard crash).
local vec
local okv = pcall(function() vec = world.items.other[item_type_name] end)
if not okv or not vec then
    report.error = 'Unknown or unreadable item type: ' .. item_type_name
    finish(); return
end

-- Walk up the container chain to the item physically sitting on a map tile.
local function root_item(it)
    local c = dfhack.items.getContainer(it)
    if not c then return it end
    while true do
        local c2 = dfhack.items.getContainer(c)
        if not c2 then return c end
        c = c2
    end
end

-- Best-effort readable name for a stockpile building.
local function sp_name(b)
    local nm = ''
    pcall(function() nm = tostring(b.name) end)
    return nm ~= '' and nm or ('Stockpile #' .. tostring(b.stockpile_number))
end

local buckets = {}   -- named stockpiles / buildings / unit carriers
local function accum(key, label, pos, n)
    if not buckets[key] then
        buckets[key] = { label = label, pos = pos,
                         item_count = 0, stack_units = 0 }
    end
    buckets[key].item_count  = buckets[key].item_count  + 1
    buckets[key].stack_units = buckets[key].stack_units + n
end

-- Ground items tracked separately: per tile and per z-level.
local ground_by_tile = {}   -- "x,y,z" -> stack_units
local ground_by_z    = {}   -- z        -> stack_units
local ground_items, ground_units = 0, 0

-- Per-item detail, capped: the formatter lists these (exact coords + where) when
-- the filtered result is small; a too-broad query just falls back to aggregates.
local DETAIL_CAP = 250
local details = {}

local total_items, total_units = 0, 0

for _, it in ipairs(vec) do
    pcall(function()
        if it.flags.garbage_collect then return end
        -- Subtype filter: skip anything that isn't the requested subtype.
        if want_subtype ~= nil and item_subtype(it) ~= want_subtype then return end

        local n = it.stack_size
        total_items = total_items + 1
        total_units = total_units + n

        local where, pos

        -- Carried by a unit (getHolderUnit walks the full container chain).
        local u = dfhack.items.getHolderUnit(it)
        if u then
            local uname = dfhack.units.getReadableName(u)
                       or ('unit#' .. tostring(u.id))
            where = 'Carried by ' .. uname
            accum('unit:' .. tostring(u.id), where, nil, n)
        else
            -- Walk to the root container to get the tile position.
            local root = root_item(it)
            local p    = root.pos
            local b    = dfhack.buildings.findAtTile(p.x, p.y, p.z)
            pos = { x = p.x, y = p.y, z = p.z }

            if b and df.building_stockpilest:is_instance(b) then
                where = sp_name(b)
                accum('sp:' .. tostring(b.id), where,
                      { x = b.x1, y = b.y1, z = b.z }, n)
            elseif b then
                local btype = df.building_type[b:getType()] or tostring(b:getType())
                where = 'In building (' .. btype .. ')'
                accum('bld:' .. tostring(b.id), where, nil, n)
            else
                where = 'Open ground'
                local tkey = p.x .. ',' .. p.y .. ',' .. p.z
                ground_by_tile[tkey] = (ground_by_tile[tkey] or 0) + n
                ground_by_z[p.z]     = (ground_by_z[p.z] or 0) + n
                ground_items = ground_items + 1
                ground_units = ground_units + n
            end
        end

        if #details < DETAIL_CAP then
            details[#details + 1] = { id = it.id, pos = pos, where = where, n = n }
        end
    end)
end

-- Build sorted location list from named buckets (stockpiles/buildings/units).
local locs = {}
for _, v in pairs(buckets) do locs[#locs + 1] = v end
table.sort(locs, function(a, b) return a.stack_units > b.stack_units end)

-- Count distinct stockpile buckets.
local sp_count = 0
for k, _ in pairs(buckets) do
    if k:sub(1, 3) == 'sp:' then sp_count = sp_count + 1 end
end

-- Build top-5 ground tile list (sorted by stack_units desc).
local ground_top = {}
for tile, n in pairs(ground_by_tile) do
    ground_top[#ground_top + 1] = { tile = tile, n = n }
end
table.sort(ground_top, function(a, b) return a.n > b.n end)
local top5 = {}
for i = 1, math.min(5, #ground_top) do top5[i] = ground_top[i] end

report.item_type       = item_type_name
report.subtype         = want_subtype
report.total_items     = total_items
report.total_units     = total_units
report.locations       = locs
report.stockpile_count = sp_count
report.items           = details
report.items_capped    = (#details >= DETAIL_CAP)
report.ground          = ground_items > 0 and {
    item_count  = ground_items,
    stack_units = ground_units,
    tile_count  = #ground_top,
    by_z        = ground_by_z,
    top_tiles   = top5,
} or nil
finish()
