-- stock_query.lua
--
-- READ-ONLY generic stock inventory. Buckets every item in the fort by its
-- item-type (DRINK, PLANT, BAR, WOOD, CLOTH, ...) and, within each type, by
-- material, leading with what the fort OWNS (on_hand) and showing
-- not-yet-acquired (webs/trade/unreachable) separately. Mutates NOTHING.
--
-- Optional FOCUS arg (an item_type name, e.g. "DRINK", "TOOL") restricts the
-- scan to that one type's vector (world.items.other[TYPE]) instead of the whole
-- ~30k-item world.items.all. This is the fast path: the full scan is what made
-- stock_data time out and blow the token cap. A FOCUS query also breaks the type
-- down by SUBTYPE (so the ~30 things sharing item_type TOOL -- nest box, jug,
-- book... -- are itemized). An optional second arg pins one subtype index.
--
-- Shared helpers (matdesc, classify_item, item_subtype, world, report, finish...)
-- come from scripts/_prelude.lua, prepended by intel.py.
--
-- Run via: RunCommand("lua", [<prelude + this file>])            full scan
--      or: RunCommand("lua", [<prelude + this file>, "TOOL"])    focused
--      or: RunCommand("lua", [<prelude + this file>, "TOOL", "10"])  one subtype

if not report.fort_loaded then finish() return end

local focus = string.upper(select(1, ...) or '')
local subtype_arg = select(2, ...)
local want_subtype = nil
if subtype_arg ~= nil and subtype_arg ~= '' then
    want_subtype = tonumber(subtype_arg)
end

local _AVAIL = { reachable = true, in_container = true }
local _INERT = { installed = true, rotten = true }
local _UNOWNED = { uncollected_web = true, loose_unreachable = true,
                   trade = true }

-- item_type name -> the itemdefs subtype table that names its subtypes, so a
-- focused breakdown can label subtype indices ("nest box") instead of numbers.
local FOCUS_TABLE = { TOOL = 'tools', WEAPON = 'weapons', ARMOR = 'armor',
    SHOES = 'shoes', HELM = 'helms', GLOVES = 'gloves', PANTS = 'pants',
    SHIELD = 'shields', AMMO = 'ammo', SIEGEAMMO = 'siege_ammo',
    TRAPCOMP = 'trapcomps', TOY = 'toys', INSTRUMENT = 'instruments',
    FOOD = 'food' }
local function sub_label(sub)
    local tbl = FOCUS_TABLE[focus]
    if not tbl then return tostring(sub) end
    local nm
    local ok = pcall(function() nm = tostring(world.raws.itemdefs[tbl][sub].name) end)
    return (ok and nm and nm ~= '') and nm or tostring(sub)
end

local cats = {}
local total_items = 0

-- Accumulate one item into its item-type category (and, in focus mode, into the
-- category's by_subtype breakdown). Same two-axis split as stock_states().
local function account(it, track_subtype)
    local st = classify_item(it)
    if st == 'dead' then return end
    total_items = total_items + 1
    local tname = df.item_type[it:getType()] or 'UNKNOWN'
    local c = cats[tname]
    if not c then
        c = { total_units = 0, free_units = 0, available = 0,
              in_transit = 0, owned_unavailable = 0, inert = 0,
              not_yet_acquired = 0, on_hand = 0, acquirable = 0,
              item_count = 0, by_material = {}, by_material_on_hand = {},
              by_material_unowned = {}, by_reason_owned = {},
              by_reason_unowned = {}, by_subtype = {} }
        cats[tname] = c
    end
    local n = it.stack_size
    c.total_units = c.total_units + n
    c.item_count = c.item_count + 1
    local key = matdesc(it)
    c.by_material[key] = (c.by_material[key] or 0) + n

    -- Subtype breakdown (focus mode only): label -> {on_hand, available}.
    if track_subtype then
        local sub = item_subtype(it)
        if sub ~= nil then
            local lbl = sub_label(sub)
            local s = c.by_subtype[lbl]
            if not s then s = { on_hand = 0, available = 0 }; c.by_subtype[lbl] = s end
            if not _UNOWNED[st] then s.on_hand = s.on_hand + n end
            if _AVAIL[st] then s.available = s.available + n end
        end
    end

    if _UNOWNED[st] then
        c.not_yet_acquired = c.not_yet_acquired + n
        c.acquirable = c.acquirable + n
        c.by_material_unowned[key] = (c.by_material_unowned[key] or 0) + n
        c.by_reason_unowned[st] = (c.by_reason_unowned[st] or 0) + n
        return
    end
    -- owned (on hand) from here on
    c.on_hand = c.on_hand + n
    c.by_material_on_hand[key] = (c.by_material_on_hand[key] or 0) + n
    if _AVAIL[st] then
        c.free_units = c.free_units + n; c.available = c.available + n
    elseif st == 'in_transit' then c.in_transit = c.in_transit + n
    elseif _INERT[st] then c.inert = c.inert + n
    else
        c.owned_unavailable = c.owned_unavailable + n
        c.acquirable = c.acquirable + n
        c.by_reason_owned[st] = (c.by_reason_owned[st] or 0) + n
    end
end

if focus ~= '' then
    -- Fast path: one type only. pcall-guard the lookup (DFHack throws on a bad
    -- items.other key -- the same crash class stockpile_locate had).
    local vec
    local okv = pcall(function() vec = world.items.other[focus] end)
    if not okv or not vec then
        report.error = 'Unknown or unreadable item type: ' .. focus
        finish(); return
    end
    report.focus = focus
    report.focus_subtype = want_subtype
    for _, it in ipairs(vec) do
        pcall(function()
            if want_subtype ~= nil and item_subtype(it) ~= want_subtype then return end
            account(it, true)
        end)
    end
else
    -- Full-fort scan, paginated by index range so each RPC chunk finishes well
    -- under the socket timeout (the unpaginated 29k-item classify pass exceeds
    -- it). start (arg 2) and limit (arg 3) are read only here; the focus branch
    -- never consumed them, so a no-arg call still means "scan everything".
    -- Parenthesize: select() returns ALL trailing args, and a bare
    -- tonumber(select(3,...)) would pass arg4 as tonumber's base. ( ) truncates
    -- to one value.
    local start = tonumber((select(2, ...))) or 0
    local limit = tonumber((select(3, ...)))  -- nil -> whole scan (legacy)
    local all = world.items.all
    local n = #all
    local stop = limit and math.min(start + limit, n) or n
    for i = start, stop - 1 do
        pcall(function() account(all[i], false) end)
    end
    -- next_cursor == nil signals the last page; the caller pages until it clears.
    report.next_cursor = (stop < n) and stop or nil
    report.scanned_total = n
    -- Per-type loose-vector length, for stockcache's classification: a type whose
    -- vector_len == item_count is "vector" (cheap, complete -> partial-refreshable);
    -- a short vector_len is "heavy" (container-backed, e.g. BOOK 17 vs 12355). The
    -- value is the FULL vector (page-independent), so reporting it on each page is
    -- safe -- the Python merge takes the first occurrence, not a sum.
    for tname, c in pairs(cats) do
        pcall(function() c.vector_len = #world.items.other[tname] end)
    end
end

-- Stamp the in-game clock + world id on every scan (both branches) so each result
-- self-dates and self-identifies for the stock baseline's bookkeeping (a focused
-- scan can then patch the right per-world cache with no extra probe RPC).
pcall(function() report.cur_year = df.global.cur_year end)
pcall(function() report.cur_year_tick = df.global.cur_year_tick end)
pcall(function() report.world_id = world.cur_savegame.world_header.id1 end)

report.total_items = total_items
report.categories = cats
finish()
