-- caravan_intel.lua
--
-- READ-ONLY view of active caravans via df.global.plotinfo.caravans: entity
-- name, trade state, mood, import value, time remaining, manifest of goods by
-- item type, animals, and liaison meeting info (diplomat name, events). Uses
-- prelude globals (world, section, finish, matname). Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end

local function entity_name(eid)
    if not eid or eid < 0 then return 'unknown' end
    local nm = ''
    pcall(function()
        local e = df.historical_entity.find(eid)
        if e then
            nm = dfhack.translation.translateName(e.name, true) or ''
            if nm == '' then nm = dfhack.translation.translateName(e.name) or '' end
        end
    end)
    return (nm ~= '') and nm or ('entity#' .. tostring(eid))
end

section('timestamp', function()
    report.cur_year      = df.global.cur_year
    report.cur_year_tick = df.global.cur_year_tick
end)

section('caravans', function()
    local cv  = df.global.plotinfo.caravans
    local out = {}
    report.caravan_count = #cv

    for _, c in ipairs(cv) do
        local rec = {}
        pcall(function() rec.entity_id = c.entity end)
        rec.entity_name = entity_name(rec.entity_id)

        -- Trade state integer (no enum in this DFHack build; 0=approaching,
        -- 1=unloading, 2=trading, 3=packing, 4=leaving — best-effort label)
        local _TRADE_STATE = {
            [0]='approaching', [1]='unloading', [2]='trading',
            [3]='packing_to_leave', [4]='leaving',
        }
        pcall(function()
            local st = c.trade_state
            rec.trade_state = _TRADE_STATE[st] or tostring(st)
        end)

        pcall(function() rec.mood           = c.mood end)
        pcall(function() rec.import_value   = c.import_value end)
        pcall(function() rec.offer_value    = c.offer_value end)
        pcall(function() rec.time_remaining = c.time_remaining end)
        pcall(function() rec.animals_count  = #c.animals end)

        -- Goods manifest: resolve each item_id to item type and count units.
        local goods_by_type, goods_units = {}, 0
        pcall(function()
            for _, item_id in ipairs(c.goods) do
                local it = df.item.find(item_id)
                if it then
                    local tname = df.item_type[it:getType()] or 'UNKNOWN'
                    local n = it.stack_size or 1
                    goods_by_type[tname] = (goods_by_type[tname] or 0) + n
                    goods_units = goods_units + n
                end
            end
        end)
        rec.goods_item_count = 0
        pcall(function() rec.goods_item_count = #c.goods end)
        rec.goods_unit_count = goods_units
        rec.goods_by_type    = goods_by_type

        out[#out + 1] = rec
    end
    report.caravans = out
end)

-- Liaison (diplomat) meeting info: who is negotiating and what year events
-- have been logged. buy_requests / sell_requests are nil until the meeting
-- completes; the goods breakdown above is the definitive manifest of what
-- the current caravan actually brought.
section('liaison', function()
    local dmi_vec = df.global.plotinfo.dip_meeting_info
    local liaisons = {}
    for _, dmi in ipairs(dmi_vec) do
        local rec = {}
        pcall(function() rec.civ_id      = dmi.civ_id end)
        pcall(function() rec.civ_name    = entity_name(dmi.civ_id) end)
        pcall(function()
            local hf = df.historical_figure.find(dmi.diplomat_id)
            if hf then
                rec.diplomat_name = dfhack.translation.translateName(hf.name, true)
            end
            rec.diplomat_id = dmi.diplomat_id
        end)
        pcall(function() rec.cur_step     = dmi.cur_step end)
        pcall(function() rec.events_count = #dmi.events end)
        liaisons[#liaisons + 1] = rec
    end
    report.liaisons = liaisons
end)

finish()
