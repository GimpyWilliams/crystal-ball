-- burrows_intel.lua
--
-- READ-ONLY intel for burrows (df.global.plotinfo.burrows.list) and which
-- citizens are assigned to them. Feeds the assign_burrow_units planner.
--   burrows[]  : id, name, blocks (map blocks the burrow touches), units (assigned)
--   citizens[] : id, name, profession, burrows (ids they belong to), syn_classes
--                (SYN_CLASS names of their active syndromes, e.g. "NECROMANCER")
-- Shared helpers (section, report, finish, world...) from scripts/_prelude.lua.
--
-- Run via: RunCommand("lua", [<prelude + this file>]).

if not report.fort_loaded then finish() return end

local function citizens()
    local ok, c = pcall(dfhack.units.getCitizens, true)
    if ok and c then return c end
    ok, c = pcall(dfhack.units.getCitizens)
    if ok and c then return c end
    return {}
end

section('burrows', function()
    local out = {}
    for _, b in ipairs(df.global.plotinfo.burrows.list) do
        local nu, nb = 0, 0
        pcall(function() nu = #b.units end)
        pcall(function() nb = #b.block_x end)
        out[#out + 1] = {
            id = b.id, name = tostring(b.name), blocks = nb, units = nu,
        }
    end
    report.burrows = out
end)

section('citizens', function()
    local list = df.global.plotinfo.burrows.list
    local syn_cache = {}
    local function classes_of(stype)
        if syn_cache[stype] == nil then
            local names = {}
            local sy = df.syndrome.find(stype)
            if sy then
                for _, c in ipairs(sy.syn_class) do names[#names + 1] = c.value end
            end
            syn_cache[stype] = names
        end
        return syn_cache[stype]
    end

    local out = {}
    for _, u in ipairs(citizens()) do
        local member = {}
        for _, b in ipairs(list) do
            if dfhack.burrows.isAssignedUnit(b, u) then member[#member + 1] = b.id end
        end
        local seen, classes = {}, {}
        for _, s in ipairs(u.syndromes.active) do
            for _, cn in ipairs(classes_of(s.type)) do
                if not seen[cn] then seen[cn] = true classes[#classes + 1] = cn end
            end
        end
        out[#out + 1] = {
            id = u.id,
            name = dfhack.units.getReadableName(u),
            profession = tostring(df.profession[u.profession]),
            burrows = member,
            syn_classes = classes,
        }
    end
    report.citizens = out
end)

finish()
