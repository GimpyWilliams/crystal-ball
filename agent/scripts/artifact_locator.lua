-- artifact_locator.lua
--
-- READ-ONLY lookup of ONE artifact by the first argument: a numeric artifact id
-- or a (case-insensitive) name substring. If the selector is missing or matches
-- several artifacts, returns the candidate list instead so the caller can pick.
-- On a unique match, reports the artifact's item type, material, quality, maker,
-- and its CURRENT physical location (held by a unit / inside a container / built
-- into a building / lying at x,y,z), or lost = true when the item is gone.
-- Shared helpers (world, report, section, finish, matdesc, histfig_name...) come
-- from scripts/_prelude.lua, prepended by intel.py. Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>, "<id or name>"]).

if not report.fort_loaded then finish() return end

local selector = select(1, ...)

-- The DWARVISH (romanized) name is the form players see in-game, e.g.
-- "Zodost Mogshum"; translate(name, true) gives the English meaning instead
-- ("The Rot of Elbows"). Use dwarvish as the primary name and match against both.
local function art_name(a)
    local nm = ''
    pcall(function() nm = dfhack.translation.translateName(a.name) end)
    return (nm ~= '') and nm or ('artifact#' .. tostring(a.id))
end

local function art_name_en(a)
    local nm = ''
    pcall(function() nm = dfhack.translation.translateName(a.name, true) end)
    return nm
end

-- A world has tens of thousands of (worldgen) artifacts and DF keeps their items
-- resident, so .item is non-nil and world.items.all membership do NOT distinguish
-- fort-present ones -- and translating every name to match would be far too slow.
-- An artifact actually IN the fort has its item placed (on the ground, built into
-- a building, or in someone's inventory); that flag check is cheap, so filter on
-- it first and translate only the resulting handful. A numeric id selector is
-- matched against ALL artifacts (no name translation needed).
local function placed(it)
    local f = it.flags
    return f.on_ground or f.in_building or f.in_inventory
end

local present = {}
for _, a in ipairs(world.artifacts.all) do
    if a.item and placed(a.item) then present[#present + 1] = a end
end

local as_num = selector and tonumber(selector)
local by_id = as_num and math.floor(as_num) == as_num

local hits = {}
if selector and selector ~= '' then
    if by_id then
        for _, a in ipairs(world.artifacts.all) do
            if a.id == as_num then hits[#hits + 1] = a end
        end
    else
        local needle = string.lower(selector)
        for _, a in ipairs(present) do
            if string.find(string.lower(art_name(a)), needle, 1, true)
                    or string.find(string.lower(art_name_en(a)), needle, 1, true) then
                hits[#hits + 1] = a
            end
        end
    end
end

-- No usable selection: hand back the fort-present artifact list to choose from.
if #hits ~= 1 then
    local candidates = {}
    for _, a in ipairs(present) do
        candidates[#candidates + 1] = { id = a.id, name = art_name(a) }
    end
    report.present_count = #present
    report.matched = #hits
    report.need_selection = true
    report.message = (selector == nil or selector == '')
        and 'No artifact selected; pass an id or name. Fort-present artifacts listed.'
        or (#hits == 0 and ('No fort-present artifact matched "'
                .. tostring(selector) .. '" (worldgen artifacts elsewhere are not listed).')
            or 'Several artifacts matched "' .. tostring(selector)
               .. '"; narrow it down.')
    report.candidates = candidates
    finish()
    return
end

local a = hits[1]
local art = { id = a.id, name = art_name(a), name_en = art_name_en(a) }

section('item', function()
    local it = a.item
    if not it then
        art.lost = true
        return
    end
    art.item_type = df.item_type[it:getType()] or tostring(it:getType())
    art.material = matdesc(it)
    pcall(function() art.quality = df.item_quality[it.quality] or it.quality end)
    pcall(function()
        if it.maker and it.maker >= 0 then
            art.maker = histfig_name(histfig_by_id(it.maker))
        end
    end)

    -- Current location: position plus the holder chain (unit / container item /
    -- built building). Any of these may be absent; report what's there.
    local loc = {}
    pcall(function() loc.x, loc.y, loc.z = it.pos.x, it.pos.y, it.pos.z end)
    pcall(function() loc.forbidden = it.flags.forbid or false end)
    pcall(function()
        local u = dfhack.items.getHolderUnit(it)
        if u then loc.held_by = dfhack.units.getReadableName(u) end
    end)
    pcall(function()
        local c = dfhack.items.getContainer(it)
        if c then
            loc.inside_item = df.item_type[c:getType()] or tostring(c:getType())
        end
    end)
    pcall(function()
        local ref = dfhack.items.getGeneralRef(
            it, df.general_ref_type.BUILDING_HOLDER)
        if ref then
            local b = ref:getBuilding()
            if b then
                loc.in_building =
                    (df.building_type[b:getType()] or tostring(b:getType()))
            end
        end
    end)
    art.location = loc
end)

report.artifact = art
finish()
