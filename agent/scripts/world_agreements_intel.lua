-- world_agreements_intel.lua
--
-- READ-ONLY diplomatic agreements and entity relations. Probes multiple struct
-- paths for DF 50.x compatibility and reports which ones are accessible. Uses
-- prelude globals. Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end

local function translate_entity_name(he)
    local nm = ''
    pcall(function()
        nm = dfhack.translation.translateName(he.name, true) or ''
        if nm == '' then nm = dfhack.translation.translateName(he.name) or '' end
    end)
    return (nm ~= '') and nm or nil
end

-- PROBE: establish which global paths exist. Always runs so failures are
-- self-diagnosing even when every subsequent section errors out.
section('probe', function()
    local pr = {}

    -- Path A: world.diplomacy (primary in DF 50)
    local okA, errA = pcall(function()
        local d = df.global.world.diplomacy
        pr.diplomacy_type          = tostring(d)
        pr.diplomacy_entity_count  = #d.entities
    end)
    if not okA then pr.diplomacy_error = tostring(errA) end

    -- Path B: world.agreements (uncertain in DF 50)
    local okB, errB = pcall(function()
        local wa = df.global.world.agreements
        pr.agreements_type  = tostring(wa)
        pr.agreements_count = #wa
    end)
    if not okB then pr.agreements_error = tostring(errB) end

    -- Path C: world.world_data (alternate diplomacy subtree)
    local okC, errC = pcall(function()
        pr.world_data_type = tostring(df.global.world.world_data)
    end)
    if not okC then pr.world_data_error = tostring(errC) end

    report.probe = pr
end)

-- LIAISON MEETINGS: plotinfo.dip_meeting_info holds active liaison/diplomat
-- meetings. Each entry has the civ_id, diplomat histfig, and event log.
-- This is the primary diplomatic data source in this DFHack version.
section('diplomacy', function()
    local meetings = {}
    for _, dmi in ipairs(df.global.plotinfo.dip_meeting_info) do
        pcall(function()
            local rec = {}
            pcall(function() rec.civ_id = dmi.civ_id end)
            pcall(function()
                local e = df.historical_entity.find(dmi.civ_id)
                if e then
                    rec.civ_name = translate_entity_name(e)
                    rec.civ_type = tostring(
                        df.historical_entity_type[e.type] or e.type)
                end
            end)
            pcall(function()
                local hf = df.historical_figure.find(dmi.diplomat_id)
                if hf then
                    rec.diplomat_name = translate_entity_name(hf)
                end
                rec.diplomat_id = dmi.diplomat_id
            end)
            pcall(function() rec.cur_step     = dmi.cur_step end)
            pcall(function() rec.events_count = #dmi.events end)
            -- Summarise events: type and year
            local evts = {}
            pcall(function()
                for _, ev in ipairs(dmi.events) do
                    local er = {}
                    pcall(function() er.type = ev.type end)
                    pcall(function() er.year = ev.year end)
                    pcall(function() er.ticks = ev.ticks end)
                    evts[#evts + 1] = er
                end
            end)
            rec.events = evts
            meetings[#meetings + 1] = rec
        end)
    end
    report.diplomacy_entities = meetings
end)

-- DIRECT AGREEMENTS: only meaningful if probe path B succeeded.
section('agreements_direct', function()
    local wa = df.global.world.agreements
    if wa == nil then return end
    local agreements = {}
    for _, a in ipairs(wa) do
        pcall(function()
            local rec = {}
            pcall(function() rec.id = a.id end)
            pcall(function()
                local party_ids = {}
                for _, pid in ipairs(a.parties or a.entity_ids or {}) do
                    party_ids[#party_ids + 1] = pid
                end
                if #party_ids > 0 then rec.party_ids = party_ids end
            end)
            pcall(function()
                local raw = a._type or a.type
                if raw ~= nil then rec.type_raw = tostring(raw) end
            end)
            agreements[#agreements + 1] = rec
        end)
    end
    report.agreements = agreements
end)

finish()
