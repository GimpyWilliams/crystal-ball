-- acquirable_items.lua
--
-- READ-ONLY. The inverse of the "available stock" reports: surface every item
-- that is NOT freely available to a workshop right now but COULD be recovered --
-- uncollected spider webs, cargo on a (possibly stranded) hauler, stuff loose on
-- the ground (especially deep in the caverns), items claimed by a job, and items
-- a single designation away (forbidden / dumped / marked for trade). This is the
-- logistics / acquisition lens; the industry reports answer "what can I use now",
-- this answers "what's out there and how do I go get it". Mutates NOTHING.
--
-- Optional arg: an item_type name (e.g. "THREAD") to focus on one type; omit for
-- a fort-wide roll-up. Shared helpers (classify_item, fort_walk_group, matdesc,
-- root_item-style container walk, world, report, finish...) come from _prelude.lua.
--
-- Run via: RunCommand("lua", [<prelude + this file>, "THREAD"])

if not report.fort_loaded then finish() return end

local focus = string.upper(select(1, ...) or '')
report.item_type = focus ~= '' and focus or 'ALL'
report.fort_walk_group = fort_walk_group()

-- Walk up the container chain to the item physically on a map tile.
local function root_item(it)
    local c = dfhack.items.getContainer(it)
    if not c then return it end
    while true do
        local c2 = dfhack.items.getContainer(c)
        if not c2 then return c end
        c = c2
    end
end

-- Which item vector(s) to scan.
local function each_item(fn)
    if focus ~= '' then
        local vec = world.items.other[focus]
        if not vec then report.error = 'Unknown item type: ' .. focus; return end
        for _, it in ipairs(vec) do pcall(fn, it) end
    else
        for _, it in ipairs(world.items.all) do pcall(fn, it) end
    end
end

-- Acquisition reasons we surface, each with a "how to get it" hint. Anything in
-- one of these states is recoverable; everything else is available / in transit /
-- inert and handled by the normal stock reports.
local HINTS = {
    uncollected_web  = 'queue Collect Webs (thread still in the web)',
    loose_unreachable= 'no walkable path from the fort -- bridge/dig/clear danger to reach it',
    loose            = 'loose on the ground -- needs a hauler, or no stockpile accepts it',
    carried          = 'being carried by a unit -- may be stuck/stranded; check the dwarf',
    claimed_job      = 'reserved by a job -- already committed, will resolve when the job runs',
    forbidden        = 'forbidden -- unforbid to release it',
    dumped           = 'marked for dumping -- reclaim to keep it',
    melt             = 'marked for melting -- reclaim to keep it',
    trade            = 'owned by a trader / at the depot -- not yours yet',
}

-- state histogram (every non-dead item) so the totals reconcile and we can see
-- exactly how the classifier bucketed the fort.
local states = {}   -- state -> {items, units}
local function bump(tbl, key, n)
    local e = tbl[key]; if not e then e = { items = 0, units = 0 }; tbl[key] = e end
    e.items = e.items + 1; e.units = e.units + n
end

-- per-reason buckets, with ground scatter (per z, top tiles) and carriers.
local buckets = {}  -- reason -> {items, units, by_z={}, by_tile={}, by_mat={}}
local function bucket(reason, it, n)
    local b = buckets[reason]
    if not b then
        b = { items = 0, units = 0, by_z = {}, by_tile = {}, by_mat = {} }
        buckets[reason] = b
    end
    b.items = b.items + 1; b.units = b.units + n
    b.by_mat[matdesc(it)] = (b.by_mat[matdesc(it)] or 0) + n
end

local carriers = {}  -- unit id -> {name, units}

each_item(function(it)
    if it.flags.garbage_collect or it.flags.removed then return end
    local n = it.stack_size
    local st = classify_item(it)

    -- Split the catch-all 'reachable' state into stockpiled vs loose so loose
    -- ground stock (reachable, but not yet stored) is visible -- a hauling
    -- candidate. The findAtTile lookup is too slow to run on all ~30k fort items
    -- (it poisons the single-threaded RPC), so we only do it in FOCUSED mode
    -- (one item_type's vector). Fort-wide leaves these as plain 'reachable'.
    -- Either way both remain "available" to a job; loose just isn't tidy.
    if st == 'reachable' and focus ~= '' then
        local root = root_item(it)
        local p = root.pos
        local b = p and dfhack.buildings.findAtTile(p.x, p.y, p.z)
        st = (b and df.building_stockpilest:is_instance(b)) and 'stockpiled' or 'loose'
    end

    bump(states, st, n)
    if not HINTS[st] then return end  -- stockpiled / in_container / in_transit / inert: not a target

    bucket(st, it, n)

    if st == 'carried' then
        local u = dfhack.items.getHolderUnit(it)
        if u then
            local id = u.id
            local c = carriers[id]
            if not c then
                local nm = dfhack.units.getReadableName(u) or ('unit#' .. id)
                c = { name = nm, units = 0 }; carriers[id] = c
            end
            c.units = c.units + n
        end
    elseif st == 'loose' or st == 'loose_unreachable' then
        local root = root_item(it)
        local p = root.pos
        if p then
            local b = buckets[st]
            b.by_z[p.z] = (b.by_z[p.z] or 0) + n
            local tk = p.x .. ',' .. p.y .. ',' .. p.z
            b.by_tile[tk] = (b.by_tile[tk] or 0) + n
        end
    end
end)

-- Shape buckets for output: top-5 tiles, by_z map, top materials.
local out = {}
for reason, b in pairs(buckets) do
    local tiles = {}
    for tile, u in pairs(b.by_tile) do tiles[#tiles + 1] = { tile = tile, units = u } end
    table.sort(tiles, function(a, c) return a.units > c.units end)
    local top5 = {}
    for i = 1, math.min(5, #tiles) do top5[i] = tiles[i] end

    local mats = {}
    for m, u in pairs(b.by_mat) do mats[#mats + 1] = { material = m, units = u } end
    table.sort(mats, function(a, c) return a.units > c.units end)

    out[#out + 1] = {
        reason = reason, hint = HINTS[reason],
        items = b.items, units = b.units,
        by_z = b.by_z, tile_count = #tiles, top_tiles = top5,
        top_materials = mats,
    }
end
table.sort(out, function(a, c) return a.units > c.units end)

local carrier_list = {}
for _, c in pairs(carriers) do carrier_list[#carrier_list + 1] = c end
table.sort(carrier_list, function(a, c) return a.units > c.units end)

report.states   = states        -- full classifier histogram (reconciliation)
report.buckets  = out           -- acquisition targets, by reason
report.carriers = carrier_list  -- who is carrying acquirable cargo
finish()
