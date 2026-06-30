-- container_audit.lua
--
-- READ-ONLY storage audit. For each container kind (barrels, large pots, bins,
-- bags, chests) reports how many exist and -- capacity-aware, not just binary --
-- how many are empty / partly full / (nearly) full, the average fill %, and how
-- many are forbidden. Storage starvation (no empty barrel, every bin full)
-- silently stalls many pipelines, so this is the first thing to check when output
-- "won't store". The nearly-full containers are listed with their position and
-- stockpile so a specific blocker is findable. Mutates NOTHING.
--
-- Bags are split out from chests/coffers (both are item_type BOX): a bag is a BOX
-- of a SOFT material (cloth/silk/yarn/leather -- lacks the ITEMS_HARD material
-- flag), and bags are the critical container for sand / flour / gypsum / seeds,
-- so they must not be blurred together with wooden chests.
--
-- Shared helpers (section, matdesc, world, report, finish, fort_loaded) come from
-- scripts/_prelude.lua, prepended by intel.py.
--
-- Run via: RunCommand("lua", [<prelude + this file>]).

if not report.fort_loaded then finish() return end

local FULL_THRESHOLD = 0.90   -- fill fraction at/above which we call it "full"
local ATTENTION_CAP  = 25     -- max nearly-full containers listed individually

-- Count + summed volume of the items inside a container.
local function contents(it)
    local n, vol = 0, 0
    for _, ref in ipairs(it.general_refs) do
        if ref:getType() == df.general_ref_type.CONTAINS_ITEM then
            n = n + 1
            local ci = df.item.find(ref.item_id)
            if ci then pcall(function() vol = vol + ci:getVolume() end) end
        end
    end
    return n, vol
end

-- Walk to the root container/item physically on a tile, for a position.
local function root_item(it)
    local c = dfhack.items.getContainer(it)
    if not c then return it end
    while true do
        local c2 = dfhack.items.getContainer(c)
        if not c2 then return c end
        c = c2
    end
end

local function sp_name(b)
    local nm = ''
    pcall(function() nm = tostring(b.name) end)
    return nm ~= '' and nm or ('Stockpile #' .. tostring(b.stockpile_number))
end

-- Where is this container? Returns (label, pos) -- best effort.
local function locate(it)
    local where, pos = nil, nil
    pcall(function()
        local u = dfhack.items.getHolderUnit(it)
        if u then where = 'carried by ' .. (dfhack.units.getReadableName(u) or ('unit#'..u.id)); return end
        local p = root_item(it).pos
        pos = { x = p.x, y = p.y, z = p.z }
        local b = dfhack.buildings.findAtTile(p.x, p.y, p.z)
        if b and df.building_stockpilest:is_instance(b) then where = sp_name(b)
        elseif b then where = 'in ' .. (df.building_type[b:getType()] or '?') end
    end)
    return where, pos
end

-- A BOX of a soft (non-ITEMS_HARD) material is a bag; otherwise a chest/coffer.
local function is_bag(it)
    local soft = false
    pcall(function()
        local mi = dfhack.matinfo.decode(it)
        soft = not (mi and mi.material and mi.material.flags.ITEMS_HARD)
    end)
    return soft
end

local attention = {}   -- nearly-full containers, across all kinds (capped)

-- Audit one set of containers. `kind` labels the attention entries.
local function audit(kind, items, pred)
    local r = { total = 0, empty = 0, partial = 0, full = 0, forbidden = 0 }
    local sum_fill = 0.0
    for _, it in ipairs(items) do
        if pred == nil or pred(it) then
            r.total = r.total + 1
            if it.flags.forbid then r.forbidden = r.forbidden + 1 end
            local n, vol = contents(it)
            local cap = 0
            pcall(function() cap = dfhack.items.getCapacity(it) end)
            local fill = (cap > 0) and (vol / cap) or (n > 0 and 1.0 or 0.0)
            if fill > 1.0 then fill = 1.0 end
            sum_fill = sum_fill + fill
            if n == 0 then
                r.empty = r.empty + 1
            elseif fill >= FULL_THRESHOLD then
                r.full = r.full + 1
                if #attention < ATTENTION_CAP then
                    local where, pos = locate(it)
                    attention[#attention + 1] = {
                        kind = kind, fill_pct = math.floor(100 * fill),
                        material = matdesc(it), where = where, pos = pos,
                    }
                end
            else
                r.partial = r.partial + 1
            end
        end
    end
    r.avg_fill_pct = (r.total > 0) and math.floor(100 * sum_fill / r.total) or 0
    return r
end

section('barrels', function()
    report.barrels = audit('barrel', world.items.other.BARREL)
end)
section('large_pots', function()
    report.large_pots = audit('large pot', world.items.other.TOOL,
        function(it) return it:isFoodStorage() end)
end)
section('bins', function()
    report.bins = audit('bin', world.items.other.BIN)
end)
section('bags', function()
    report.bags = audit('bag', world.items.other.BOX, is_bag)
end)
section('chests', function()
    report.chests = audit('chest', world.items.other.BOX,
        function(it) return not is_bag(it) end)
end)

report.attention = attention
finish()
