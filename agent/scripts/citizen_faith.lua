-- citizen_faith.lua
--
-- READ-ONLY lookup of ONE fort citizen's RELIGION by the first argument: a
-- numeric unit id or a (case-insensitive) name substring (same selector rules as
-- dwarf_detail.lua). If the selector is missing or matches several dwarves,
-- returns the candidate list instead. On a unique match, reports the deity/
-- deities the dwarf worships (with worship strength) and which fort temple (if
-- any) serves each -- i.e. where an artifact this dwarf made could be placed.
-- Shared helpers (world, report, section, finish, histfig_name, deity_spheres,
-- histfig_by_id, fort_temples...) come from scripts/_prelude.lua. Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>, "<id or name>"]).

if not report.fort_loaded then finish() return end

local selector = select(1, ...)

local function unit_name(u)
    local n
    pcall(function() n = dfhack.units.getReadableName(u) end)
    if n and n ~= '' then return n end
    return 'unit#' .. tostring(u.id)
end

local function profession(u)
    local p
    pcall(function() p = dfhack.units.getProfessionName(u) end)
    return p or '?'
end

local function is_citizen(u)
    local ok = false
    pcall(function()
        ok = (dfhack.units.isCitizen(u) or dfhack.units.isResident(u))
             and dfhack.units.isActive(u)
    end)
    return ok
end

local citizens = {}
for _, u in ipairs(world.units.active) do
    if is_citizen(u) then citizens[#citizens + 1] = u end
end

local function matches(u)
    if selector == nil or selector == '' then return false end
    local as_num = tonumber(selector)
    if as_num and math.floor(as_num) == as_num then
        return u.id == as_num
    end
    return string.find(string.lower(unit_name(u)),
                       string.lower(selector), 1, true) ~= nil
end

local hits = {}
if selector and selector ~= '' then
    for _, u in ipairs(citizens) do
        if matches(u) then hits[#hits + 1] = u end
    end
end

if #hits ~= 1 then
    local candidates = {}
    for _, u in ipairs(citizens) do
        candidates[#candidates + 1] =
            { id = u.id, name = unit_name(u), profession = profession(u) }
    end
    report.matched = #hits
    report.need_selection = true
    report.message = (selector == nil or selector == '')
        and 'No dwarf selected; pass an id or name. Candidates listed.'
        or (#hits == 0 and 'No citizen matched "' .. tostring(selector) .. '".'
            or 'Several citizens matched "' .. tostring(selector)
               .. '"; narrow it down.')
    report.candidates = candidates
    finish()
    return
end

local target = hits[1]
local f = { id = target.id, name = unit_name(target),
            profession = profession(target) }

section('worship', function()
    local hf = histfig_by_id(target.hist_figure_id)
    if not hf then
        f.note = 'this dwarf has no historical figure record (no worship data)'
        f.deities = {}
        return
    end
    -- Pre-index fort temples by the deity histfig id they serve.
    local temples_by_deity = {}
    for _, t in ipairs(fort_temples()) do
        if t.deity_hfid then
            local lst = temples_by_deity[t.deity_hfid] or {}
            lst[#lst + 1] = t.name
            temples_by_deity[t.deity_hfid] = lst
        end
    end
    -- Deity worship links live in the historical figure's histfig_links. The
    -- link KIND is the subclass, read via link:getType() (there is no link_type
    -- field); DEITY links carry the deity's histfig id in target_hf and the
    -- worship intensity in link_strength.
    local deities = {}
    for _, link in ipairs(hf.histfig_links) do
        local is_deity_link = false
        pcall(function()
            is_deity_link = (link:getType() == df.histfig_hf_link_type.DEITY)
        end)
        if is_deity_link then
            local dhf = histfig_by_id(link.target_hf)
            deities[#deities + 1] = {
                deity = dhf and histfig_name(dhf) or ('histfig#' .. link.target_hf),
                strength = link.link_strength,
                spheres = dhf and deity_spheres(dhf) or {},
                temples = temples_by_deity[link.target_hf] or {},
            }
        end
    end
    table.sort(deities, function(x, y)
        return (x.strength or 0) > (y.strength or 0)
    end)
    f.deities = deities
end)

report.dwarf = f
finish()
