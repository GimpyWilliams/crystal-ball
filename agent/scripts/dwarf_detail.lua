-- dwarf_detail.lua
--
-- READ-ONLY deep profile of ONE fort citizen, selected by the first argument:
-- either a numeric unit id or a (case-insensitive) name substring. If the
-- selector is missing or matches several dwarves, returns the candidate list
-- instead so the caller can pick. Reports labors, skills, current job + idle
-- reason, needs, recent thoughts/emotions, stress/mood, and health counters.
-- The selector is treated strictly as a lookup value, never executed.
-- Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>, "<id or name>"]).

local json = require('json')

local report = { errors = {} }
report.fort_loaded = (df.global.world.map.block_index ~= nil)
if not report.fort_loaded then
    print(json.encode(report))
    return
end

local selector = select(1, ...)

local function section(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        report.errors[#report.errors + 1] = name .. ': ' .. tostring(err)
    end
end

local function unit_name(u)
    local n
    pcall(function() n = dfhack.units.getReadableName(u) end)
    if n and n ~= '' then return n end
    pcall(function() n = dfhack.TranslateName(dfhack.units.getVisibleName(u)) end)
    return (n and n ~= '') and n or ('unit#' .. u.id)
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

-- Gather candidate citizens, optionally filtered by the selector.
local citizens = {}
for _, u in ipairs(df.global.world.units.active) do
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

local target = nil
local hits = {}
if selector and selector ~= '' then
    for _, u in ipairs(citizens) do
        if matches(u) then hits[#hits + 1] = u end
    end
end

-- No usable selection: hand back the roster of names/ids to choose from.
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
    print(json.encode(report))
    return
end

target = hits[1]
local d = { id = target.id, name = unit_name(target),
            profession = profession(target) }

section('identity', function()
    d.sex = (target.sex == 1) and 'male'
        or (target.sex == 0) and 'female' or 'other'
    d.position = { x = target.pos.x, y = target.pos.y, z = target.pos.z }
    if target.mood and target.mood >= 0 then
        d.mood = df.mood_type[target.mood] or tostring(target.mood)
    else
        d.mood = 'none'
    end
    local species = 'unknown'
    pcall(function()
        local r = df.global.world.raws.creatures.all[target.race]
        if r then species = r.creature_id end
    end)
    d.species = species
end)

section('job', function()
    local j = target.job.current_job
    if j then
        d.current_job = df.job_type[j.job_type] or tostring(j.job_type)
        d.job_suspended = j.flags.suspend or false
    else
        d.current_job = 'Idle'
    end
end)

section('stress', function()
    local p = target.status.current_soul.personality
    d.stress = p.stress
end)

section('labors', function()
    -- df.unit_labor entries are only reachable by numeric index (pairs() on
    -- the enum yields nothing useful), so walk 0.._last_item.
    local enabled = {}
    local last = df.unit_labor._last_item or 200
    for i = 0, last do
        local name = df.unit_labor[i]
        if name and not name:match('^UNUSED') and target.status.labors[i] then
            enabled[#enabled + 1] = name
        end
    end
    table.sort(enabled)
    d.labors_enabled = enabled
end)

section('skills', function()
    local skills = {}
    for _, sk in ipairs(target.status.current_soul.skills) do
        skills[#skills + 1] = {
            skill = df.job_skill[sk.id] or tostring(sk.id),
            level = sk.rating,
        }
    end
    table.sort(skills, function(a, b) return a.level > b.level end)
    d.skills = skills
end)

section('needs', function()
    local needs = {}
    for _, nd in ipairs(target.status.current_soul.personality.needs) do
        needs[#needs + 1] = {
            need = df.need_type[nd.id] or tostring(nd.id),
            focus_level = nd.focus_level,
            need_level = nd.need_level,
        }
    end
    d.needs = needs
end)

section('thoughts', function()
    -- Most-recent emotions are the practical "how does this dwarf feel".
    -- Copy via ipairs (DFHack vectors are 0-based) then keep the last few.
    local all = {}
    for _, e in ipairs(target.status.current_soul.personality.emotions) do
        all[#all + 1] = e
    end
    local out = {}
    for i = math.max(1, #all - 7), #all do
        local e = all[i]
        out[#out + 1] = {
            emotion = df.emotion_type[e.type] or tostring(e.type),
            thought = df.unit_thought_type[e.thought] or tostring(e.thought),
            strength = e.strength,
        }
    end
    d.recent_thoughts = out
end)

section('health', function()
    local h = {}
    pcall(function() h.wounds = #target.body.wounds end)
    pcall(function() h.hunger_timer = target.counters2.hunger_timer end)
    pcall(function() h.thirst_timer = target.counters2.thirst_timer end)
    pcall(function() h.sleepiness_timer = target.counters2.sleepiness_timer end)
    d.health = h
end)

report.dwarf = d
print(json.encode(report))
