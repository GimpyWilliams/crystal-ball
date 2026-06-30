-- _prelude.lua
--
-- Canonical helpers shared by every READ-ONLY intel/diagnose query. intel.py's
-- run_intel() prepends this file to each script before sending it over the
-- DFHack RPC, so the functions below are available as GLOBALS to every script.
-- This is the single source of truth for material decoding and item-availability
-- logic -- fix a gotcha here, fix it everywhere. Mutates NOTHING.

json = require('json')
world = df.global.world

-- Shared report table. Scripts add their own fields (sections, target, facts...)
-- and call finish() at the end. fort_loaded lets a script bail early when no
-- fortress map is loaded (the world arrays are empty at the main menu).
report = { errors = {} }
report.fort_loaded = (world.map.block_index ~= nil)

-- Run one report section; a field-name change in a future DF version degrades
-- that one section to an error note instead of breaking the whole report.
function section(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        report.errors[#report.errors + 1] = name .. ': ' .. tostring(err)
    end
end

-- Append a diagnose check. severity: 'blocker' or 'info'; ok is true/false, or
-- nil when the check could not be evaluated.
function add(name, ok, severity, detail)
    report.checks = report.checks or {}
    report.checks[#report.checks + 1] =
        { name = name, ok = ok, severity = severity, detail = detail }
end

-- Material name from a (mat_type, mat_index) pair, with a readable fallback.
function matname(mat_type, mat_index)
    local mi = dfhack.matinfo.decode(mat_type, mat_index)
    return mi and mi:toString()
        or ('mat:' .. tostring(mat_type) .. ':' .. tostring(mat_index))
end

-- Material name for a whole ITEM. Decoding the item directly handles
-- creature-derived items (fish, etc.) whose mat_type fields don't resolve via
-- matinfo.decode(t, i). Falls back to the item's material getters.
function matdesc(it)
    local mi = dfhack.matinfo.decode(it)
    if mi then return mi:toString() end
    return matname(it:getMaterial(), it:getMaterialIndex())
end

-- ---------------------------------------------------------------------------
-- Item state classification: the single source of truth for "is this item
-- actually usable, and if not, why?". Every "free"/"on hand"/"available" count
-- in the project routes through classify_item() (via is_available() or
-- stock_states()), so a fix here fixes every industry report uniformly.
--
-- The old is_available() checked administrative flags ONLY (forbid/rotten/dump/
-- in_building/in_inventory) and so counted items no dwarf can reach -- e.g. silk
-- thread loose on a cavern floor -- as "free to weave". classify_item() adds
-- reachability (walk-group compare), the uncollected-web flag, and the in-job /
-- hauling-vs-real-job distinction, mirroring DFHack's own workflow plugin.
-- ---------------------------------------------------------------------------

-- All citizens, tolerant of getCitizens() signature differences across DF/DFHack
-- versions (the bool arg excludes residents on builds that accept it).
local function _citizens()
    local ok, c = pcall(dfhack.units.getCitizens, true)
    if ok and c then return c end
    ok, c = pcall(dfhack.units.getCitizens)
    if ok and c then return c end
    return {}
end

-- The fort's reference walkability group: the group most citizens stand in.
-- Using the PLURALITY (not "any citizen", the unforbid.lua idiom) is deliberate
-- -- a dwarf stranded in the caverns is a citizen too, and "reachable by any
-- citizen" would wrongly bless the very cavern items we want to flag. The lone
-- stranded dwarf's group loses the vote. Memoized: computed once per query (the
-- prelude is re-sent per script run, so a plain upvalue cache is per-query-safe).
local _fort_group, _fort_group_done = nil, false
function fort_walk_group()
    if _fort_group_done then return _fort_group end
    _fort_group_done = true
    local counts = {}
    pcall(function()
        for _, u in ipairs(_citizens()) do
            local g = dfhack.maps.getWalkableGroup(u.pos)
            if g and g ~= 0 then counts[g] = (counts[g] or 0) + 1 end
        end
    end)
    local best, bestn = nil, 0
    for g, n in pairs(counts) do if n > bestn then best, bestn = g, n end end
    _fort_group = best
    return _fort_group
end

-- Is the job currently committing this item a *hauling* job (StoreItemInStockpile
-- etc.)? Such items are in transit but still functionally available; only a
-- NON-hauling job truly consumes/reserves an item. Mirrors workflow's
-- itemInRealJob(). Caller guarantees it.flags.in_job is set.
function is_hauling_job(it)
    local hauling = false
    pcall(function()
        local ref = dfhack.items.getSpecificRef(it, df.specific_ref_type.JOB)
        local job = ref and ref.data and ref.data.job
        if not job then return end  -- in_job but no job ref: treat as real job
        local attrs = df.job_type.attrs[job.job_type]
        hauling = attrs and attrs.type == df.job_type_class.Hauling
    end)
    return hauling
end

-- Can a fort dwarf path to this loose item? Read the item tile's walk group from
-- the LIVE map (the same getWalkableGroup the fort anchor uses) and compare to
-- the fort reference group. We deliberately do NOT trust the item's cached
-- it.walkable_id field -- it is refreshed lazily and gives false "unreachable"
-- hits on items clearly inside the fort. HEURISTIC -- the walkable cache only
-- refreshes while unpaused and ignores burrows/invaders. When the fort group
-- can't be determined we degrade to "reachable" rather than hiding everything.
-- Caller reaches here only for items physically on a tile (it.pos is valid).
function item_reachable(it)
    local fg = fort_walk_group()
    if not fg then return true end
    local reachable = true
    pcall(function()
        local p = it.pos
        if not p or p.x < 0 then return end   -- no tile: leave as reachable
        local g = dfhack.maps.getWalkableGroup(p)
        reachable = (g ~= nil and g ~= 0 and g == fg)
    end)
    return reachable
end

-- Resolve an item to exactly one state string. Flags are checked before the
-- expensive getHolderUnit/getSpecificRef calls so we pay those only on the small
-- in_inventory / in_job subsets (preserving the old per-item cost profile).
--   reachable / in_container -> AVAILABLE now
--   in_transit               -> being hauled in (own line; not available)
--   loose_unreachable, uncollected_web, claimed_job, carried,
--     forbidden, dumped, melt, trade -> ACQUIRABLE (recoverable, see below)
--   installed, rotten        -> in total but neither available nor acquirable
--   dead                     -> excluded entirely
function classify_item(it)
    local f = it.flags
    if f.removed or f.garbage_collect then return 'dead' end
    if f.in_building or f.construction then return 'installed' end
    if f.in_inventory then
        -- in_inventory covers BOTH a unit's inventory and a barrel/bin. The
        -- holder unit (walked through the container chain) decides which.
        if dfhack.items.getHolderUnit(it) ~= nil then return 'carried' end
        return 'in_container'
    end
    if f.forbid then return 'forbidden' end
    if f.dump   then return 'dumped' end
    if f.melt   then return 'melt' end
    if f.trader then return 'trade' end
    if f.rotten then return 'rotten' end
    if f.spider_web then return 'uncollected_web' end  -- THREAD still in a web
    if f.in_job then
        return is_hauling_job(it) and 'in_transit' or 'claimed_job'
    end
    return item_reachable(it) and 'reachable' or 'loose_unreachable'
end

-- States that count as available to a workshop job right now.
local _AVAILABLE = { reachable = true, in_container = true }
-- States that exist but are neither available nor recoverable stock.
local _INERT = { installed = true, rotten = true }
-- Ownership axis, orthogonal to availability. The fort OWNS these but can't use
-- them right now -- a flag toggle or a finished job makes them available again.
local _OWNED_UNAVAIL = { forbidden = true, dumped = true, claimed_job = true,
                         carried = true, melt = true }
-- The fort does NOT own these yet: silk still in a web, items behind no path,
-- and goods that belong to a visiting caravan. These are POTENTIAL, not stock,
-- and must never be reported as "what the fort has".
local _UNOWNED = { uncollected_web = true, loose_unreachable = true,
                   trade = true }

-- "Available to a workshop job" -- now reachability-aware. Thin wrapper so every
-- existing call site is corrected without change.
function is_available(it)
    return _AVAILABLE[classify_item(it)] or false
end

-- One pass over an item-type vector, bucketed along TWO axes: availability and
-- ownership. The ownership axis is the fix for the "available vs acquired"
-- conflation -- silk still in a web counts toward neither on_hand nor available.
-- Returns:
--   available         = reachable + in_container (usable by a job now)
--   in_transit        = being hauled in (owned)
--   owned_unavailable = forbidden/dumped/claimed_job/carried/melt (owned, locked)
--   inert             = installed/rotten (owned, but not stock)
--   not_yet_acquired  = uncollected_web/loose_unreachable/trade (NOT owned yet)
--   on_hand           = available + in_transit + owned_unavailable + inert
--   total             = on_hand + not_yet_acquired (gross; dead excluded)
--   acquirable        = owned_unavailable + not_yet_acquired  [back-compat]
--   by_reason_owned   = {state -> units} for the owned-but-locked buckets
--   by_reason_unowned = {state -> units} for the not-yet-acquired buckets
--   by_reason         = union of the two  [back-compat]
--   by_material_on_hand = {material -> units} over owned items only
--   by_material_unowned = {material -> units} over not-yet-acquired items
--   by_material         = union of the two  [back-compat]
function stock_states(tname)
    local r = { available = 0, in_transit = 0, owned_unavailable = 0,
                inert = 0, not_yet_acquired = 0, on_hand = 0, total = 0,
                acquirable = 0,
                by_reason_owned = {}, by_reason_unowned = {}, by_reason = {},
                by_material_on_hand = {}, by_material_unowned = {},
                by_material = {} }
    local vec = world.items.other[tname]
    if not vec then return r end
    for _, it in ipairs(vec) do
        pcall(function()
            local st = classify_item(it)
            if st == 'dead' then return end
            local n = it.stack_size
            r.total = r.total + n
            local mat = matdesc(it)
            r.by_material[mat] = (r.by_material[mat] or 0) + n
            if _UNOWNED[st] then
                r.not_yet_acquired = r.not_yet_acquired + n
                r.acquirable = r.acquirable + n
                r.by_reason_unowned[st] = (r.by_reason_unowned[st] or 0) + n
                r.by_reason[st] = (r.by_reason[st] or 0) + n
                r.by_material_unowned[mat] = (r.by_material_unowned[mat] or 0) + n
                return
            end
            -- everything below this point is OWNED (on hand)
            r.on_hand = r.on_hand + n
            r.by_material_on_hand[mat] = (r.by_material_on_hand[mat] or 0) + n
            if _AVAILABLE[st] then
                r.available = r.available + n
            elseif st == 'in_transit' then
                r.in_transit = r.in_transit + n
            elseif _INERT[st] then
                r.inert = r.inert + n
            else  -- owned but locked: forbidden/dumped/claimed_job/carried/melt
                r.owned_unavailable = r.owned_unavailable + n
                r.acquirable = r.acquirable + n
                r.by_reason_owned[st] = (r.by_reason_owned[st] or 0) + n
                r.by_reason[st] = (r.by_reason[st] or 0) + n
            end
        end)
    end
    return r
end

-- Numeric subtype index of an item, or nil when its item_type has no subtypes.
-- Generalizes the one-off isFoodStorage() check (container_audit.lua): with the
-- raws snapshot (resolve.py), a resolved (item_type, subtype) lets any locate /
-- stock script filter TOOL/ARMOR/WEAPON/... subtypes -- e.g. nest box vs jug vs
-- book under TOOL, or an iron breastplate under ARMOR. getSubtype() returns -1
-- for types without a subtype dimension; we normalize that to nil.
function item_subtype(it)
    local s = -1
    pcall(function() s = it:getSubtype() end)
    if s == nil or s < 0 then return nil end
    return s
end

-- Work-detail labor availability for DF v50+. A labor with NO work detail is
-- done by everyone by default; a labor governed by a detail with nobody assigned
-- is a real blocker. Returns (ok, detail) for use with add().
function labor_check(labor_name)
    local wd_count, wd_units = 0, 0
    local ok = pcall(function()
        for _, wd in ipairs(df.global.plotinfo.labor_info.work_details) do
            local allows = false
            pcall(function() allows = wd.allowed_labors[labor_name] end)
            if allows then
                wd_count = wd_count + 1
                wd_units = wd_units + #wd.assigned_units
            end
        end
    end)
    if not ok then
        return nil, 'could not read work details on this DF version; check manually'
    elseif wd_count == 0 then
        return true, 'no work detail restricts this labor; any able dwarf can do it'
    elseif wd_units == 0 then
        return false, wd_count ..
            ' work detail(s) govern this labor but no dwarf is assigned'
    else
        return true, wd_units .. ' dwarf(s) assigned via work details'
    end
end

-- Count/busy of a furnace by furnace_type, or a workshop by workshop_type.
function furnaces_of(ftype)
    local total, busy = 0, 0
    for _, b in ipairs(world.buildings.all) do
        if df.building_furnacest:is_instance(b) and b.type == ftype then
            total = total + 1
            if #b.jobs > 0 then busy = busy + 1 end
        end
    end
    return total, busy
end

function workshops_of(wtype)
    local total, busy = 0, 0
    for _, b in ipairs(world.buildings.all) do
        if df.building_workshopst:is_instance(b) and b.type == wtype then
            total = total + 1
            if #b.jobs > 0 then busy = busy + 1 end
        end
    end
    return total, busy
end

-- Fort-site "locations" (abstract buildings: taverns, temples, hospitals,
-- libraries, guildhalls). In DF50 these are NOT civzones -- a hospital is an
-- abstract_building_hospitalst on the current site, not a building_civzonest, and
-- df.civzone_type has no Hospital entry at all. Returns the site's abstract
-- buildings, or {} when no fort site is loaded.
function fort_locations()
    local site = dfhack.world.getCurrentSite()
    if not site then return {} end
    return site.buildings
end

-- Readable name of a location/abstract building ("The Home of Roughness").
function location_name(ab)
    local nm = ''
    pcall(function() nm = dfhack.translation.translateName(ab.name, true) end)
    if nm == '' then pcall(function() nm = dfhack.translation.translateName(ab.name) end) end
    return nm
end

-- Count fort-site locations that match a class-test predicate, e.g.
--   count_locations(function(ab) return df.abstract_building_hospitalst:is_instance(ab) end)
function count_locations(matches)
    local n = 0
    for _, ab in ipairs(fort_locations()) do
        if matches(ab) then n = n + 1 end
    end
    return n
end

-- Readable name of a HISTORICAL FIGURE (deity, dwarf-as-histfig, ...). Same
-- pcall-fallback style as location_name; falls back to "histfig#<id>".
function histfig_name(hf)
    if not hf then return nil end
    local nm = ''
    pcall(function() nm = dfhack.translation.translateName(hf.name, true) end)
    if nm == '' then pcall(function() nm = dfhack.translation.translateName(hf.name) end) end
    return (nm ~= '') and nm or ('histfig#' .. tostring(hf.id))
end

-- A historical figure by id, or nil. (df.global.world.history.figures is a
-- vector indexed by position, not by id, so use the find helper.)
function histfig_by_id(id)
    if not id or id < 0 then return nil end
    return df.historical_figure.find(id)
end

-- Spheres/domains of a deity historical figure, as readable strings
-- (e.g. {"WEALTH", "TRADE"}). The spheres live on the figure's metaphysical
-- profile (hf.info.metaphysical.spheres), not directly on the figure. Empty
-- table if none/unreadable.
function deity_spheres(hf)
    local out = {}
    pcall(function()
        for _, s in ipairs(hf.info.metaphysical.spheres) do
            out[#out + 1] = df.sphere_type[s] or tostring(s)
        end
    end)
    return out
end

-- The deity a temple is dedicated to. On an abstract_building_templest,
-- deity_type is -1 (generic / no single dedication), 0 (dedicated to a Deity),
-- or 1 (a Religion); when it is 0, deity_data.Deity holds the deity's histfig id.
-- (df.temple_deity_type is not exposed as a global on this build, hence the
-- literal 0.) Returns the deity histfig id, or nil when the temple is generic /
-- serves a religion / the layout differs on this DF version.
function temple_deity_hfid(ab)
    local hfid = nil
    pcall(function()
        if ab.deity_type == 0 then
            hfid = ab.deity_data.Deity
        end
    end)
    return hfid
end

-- Fort-site temples as {name=..., deity_hfid=..., deity=...} records, so the
-- deity/faith tools can match a temple to a deity by histfig id.
function fort_temples()
    local out = {}
    for _, ab in ipairs(fort_locations()) do
        if df.abstract_building_templest:is_instance(ab) then
            local hfid = temple_deity_hfid(ab)
            out[#out + 1] = {
                name = location_name(ab),
                deity_hfid = hfid,
                deity = hfid and histfig_name(histfig_by_id(hfid)) or nil,
            }
        end
    end
    return out
end

function finish()
    print(json.encode(report))
end
