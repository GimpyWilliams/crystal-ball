-- deity_detail.lua
--
-- READ-ONLY lookup of ONE deity by the first argument: a (case-insensitive) name
-- substring (deities are historical figures, not fort units, so there's no unit
-- id to use). If the selector is missing or matches several deities, returns the
-- candidate list instead. On a unique match, reports the deity's spheres/domains
-- and which fort temple(s) (if any) are dedicated to it.
-- Shared helpers (world, report, section, finish, histfig_name, deity_spheres,
-- fort_temples...) come from scripts/_prelude.lua, prepended by intel.py.
-- Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>, "<name>"]).

if not report.fort_loaded then finish() return end

local selector = select(1, ...)

-- A historical figure is a deity when its flags.deity bit is set. Wrapped in
-- pcall so a flag-name change on a future DF version degrades to "no match"
-- rather than erroring out the whole scan.
local function is_deity(hf)
    local ok = false
    pcall(function() ok = hf.flags.deity end)
    return ok
end

local function matches(hf)
    if selector == nil or selector == '' then return false end
    return string.find(string.lower(histfig_name(hf)),
                       string.lower(selector), 1, true) ~= nil
end

local deities = {}
for _, hf in ipairs(world.history.figures) do
    if is_deity(hf) then deities[#deities + 1] = hf end
end

local hits = {}
if selector and selector ~= '' then
    for _, hf in ipairs(deities) do
        if matches(hf) then hits[#hits + 1] = hf end
    end
end

if #hits ~= 1 then
    local candidates = {}
    for _, hf in ipairs(deities) do
        candidates[#candidates + 1] = { id = hf.id, name = histfig_name(hf) }
    end
    report.matched = #hits
    report.need_selection = true
    report.message = (selector == nil or selector == '')
        and 'No deity selected; pass a name. Candidates listed.'
        or (#hits == 0 and 'No deity matched "' .. tostring(selector) .. '".'
            or 'Several deities matched "' .. tostring(selector)
               .. '"; narrow it down.')
    report.candidates = candidates
    finish()
    return
end

local hf = hits[1]
local d = { id = hf.id, name = histfig_name(hf) }

section('spheres', function()
    d.spheres = deity_spheres(hf)
end)

section('temples', function()
    local dedicated = {}
    for _, t in ipairs(fort_temples()) do
        if t.deity_hfid == hf.id then
            dedicated[#dedicated + 1] = t.name
        end
    end
    d.temples = dedicated
end)

report.deity = d
finish()
