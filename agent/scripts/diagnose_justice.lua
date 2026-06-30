-- diagnose_justice.lua
--
-- READ-ONLY root-cause analysis for "is fortress justice functioning?". Checks
-- that a law-enforcement official (sheriff / captain of the guard) is assigned
-- so crimes can actually be investigated and punished. Mutates NOTHING. Shared
-- helpers come from scripts/_prelude.lua.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end
report.target = 'functioning justice'
report.facts = {}

-- Tally law-enforcement positions and how many are filled.
local law_positions, law_filled, names = 0, 0, {}
pcall(function()
    local fe = df.global.plotinfo.main.fortress_entity
    if fe then
        for _, pos in ipairs(fe.positions.own) do
            local is_law = false
            pcall(function() is_law = pos.responsibilities.LAW_ENFORCEMENT == true end)
            if is_law then
                law_positions = law_positions + 1
                local assigned = 0
                pcall(function()
                    for _, a in ipairs(fe.positions.assignments) do
                        if a.position_id == pos.id and a.histfig ~= -1 then
                            assigned = assigned + 1
                        end
                    end
                end)
                if assigned > 0 then
                    law_filled = law_filled + 1
                    pcall(function() names[#names + 1] = pos.name[0] end)
                end
            end
        end
    end
end)
report.facts.law_positions = law_positions
report.facts.law_filled = law_filled

-- 1. Does the fort even define a law-enforcement position?
add('law_position_exists', law_positions > 0, 'blocker',
    law_positions .. ' law-enforcement position(s) defined (e.g. sheriff)')

-- 2. Is one actually filled? An unfilled sheriff/captain means crimes go
-- uninvestigated and unpunished.
local detail = law_filled .. ' filled'
if law_filled > 0 then detail = detail .. ' (' .. table.concat(names, ', ') .. ')' end
add('law_officer_assigned', law_filled > 0, 'blocker', detail)

-- 3. Crime caseload (context).
local crimes = 0
pcall(function() crimes = #world.crimes.all end)
report.facts.crimes_logged = crimes
add('crime_caseload', crimes == 0, 'info', crimes .. ' crime(s) currently logged')

finish()
