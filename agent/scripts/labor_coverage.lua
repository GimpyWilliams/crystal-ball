-- labor_coverage.lua
--
-- READ-ONLY answer to "who can do <labor>, and are they available?".
-- First argument is a labor name (e.g. BREWER, COOK, MASON); defaults to BREWER.
-- Lists every citizen with that labor enabled, whether they're idle or busy,
-- and their stress -- plus any work details that govern the labor. This is the
-- "is anyone actually able to do this job" check. The labor name is treated
-- strictly as an enum lookup, never executed. Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>, "BREWER"]).

local json = require('json')

local report = { errors = {} }
report.fort_loaded = (df.global.world.map.block_index ~= nil)
if not report.fort_loaded then
    print(json.encode(report))
    return
end

local arg = select(1, ...)
local labor_name = (arg and arg ~= '') and string.upper(arg) or 'BREWER'
report.labor = labor_name

local labor_val = df.unit_labor[labor_name]
if type(labor_val) ~= 'number' then
    report.error = 'unknown labor "' .. labor_name
        .. '". Use a df.unit_labor name like BREWER, COOK, MASON, HAUL_FOOD.'
    print(json.encode(report))
    return
end

local function unit_name(u)
    local n
    pcall(function() n = dfhack.units.getReadableName(u) end)
    if n and n ~= '' then return n end
    pcall(function() n = dfhack.TranslateName(dfhack.units.getVisibleName(u)) end)
    return (n and n ~= '') and n or ('unit#' .. u.id)
end

local function is_citizen(u)
    local ok = false
    pcall(function()
        ok = (dfhack.units.isCitizen(u) or dfhack.units.isResident(u))
             and dfhack.units.isActive(u)
    end)
    return ok
end

local workers, citizens_total = {}, 0
local ok, err = pcall(function()
    for _, u in ipairs(df.global.world.units.active) do
        if is_citizen(u) then
            citizens_total = citizens_total + 1
            if u.status.labors[labor_val] then
                local busy = (u.job.current_job ~= nil)
                local stress
                pcall(function()
                    stress = u.status.current_soul.personality.stress
                end)
                workers[#workers + 1] = {
                    id = u.id, name = unit_name(u),
                    busy = busy, stress = stress,
                }
            end
        end
    end
end)
if not ok then
    report.errors[#report.errors + 1] = 'workers: ' .. tostring(err)
end

report.citizens_total = citizens_total
report.enabled_count = #workers
report.workers = workers

-- Work details that govern this labor (v50+). If none, the labor is
-- unrestricted and any able citizen does it by default.
local _ = pcall(function()
    local details = {}
    for _, wd in ipairs(df.global.plotinfo.labor_info.work_details) do
        local allows = false
        pcall(function() allows = wd.allowed_labors[labor_name] end)
        if allows then
            details[#details + 1] =
                { name = wd.name, assigned_units = #wd.assigned_units }
        end
    end
    report.work_details = details
end)

print(json.encode(report))
