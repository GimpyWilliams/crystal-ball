-- justice_intel.lua
--
-- READ-ONLY fortress intelligence for the justice subsystem: law-enforcement
-- positions (sheriff / captain of the guard) and logged crimes. Mutates
-- NOTHING. Shared helpers (section, world, report, finish...) come from
-- scripts/_prelude.lua, prepended by intel.py.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end

-- Law-enforcement positions defined by the player's own fort entity, with how
-- many slots are filled. Scoped to the fortress entity so we don't enumerate
-- every civilization's nobles.
section('law_enforcement', function()
    local positions = {}
    local fe = df.global.plotinfo.main.fortress_entity
    if fe then
        for _, pos in ipairs(fe.positions.own) do
            local is_law = false
            pcall(function() is_law = pos.responsibilities.LAW_ENFORCEMENT == true end)
            if is_law then
                local name = '?'
                pcall(function() name = pos.name[0] end)
                local cap = 0
                pcall(function() cap = pos.number end)
                local assigned = 0
                pcall(function()
                    for _, a in ipairs(fe.positions.assignments) do
                        if a.position_id == pos.id and a.histfig ~= -1 then
                            assigned = assigned + 1
                        end
                    end
                end)
                positions[#positions + 1] =
                    { name = name, capacity = cap, assigned = assigned }
            end
        end
    end
    report.law_enforcement = positions
end)

-- Logged crimes in the fort. Resolved cases are generally pruned, so this
-- approximates the open/recent caseload.
section('crimes', function()
    report.crimes_logged = #world.crimes.all
end)

finish()
