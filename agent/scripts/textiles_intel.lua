-- textiles_intel.lua
--
-- READ-ONLY fortress intelligence for the textiles / clothing industry
-- (thread -> cloth at a Loom -> clothes at a Clothier's). Mutates NOTHING.
-- Shared helpers (section, matdesc, is_available, workshops_of, world, report,
-- finish...) come from scripts/_prelude.lua, prepended by intel.py.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end

-- 1. Thread on hand (the input to weaving). stock_states() reports available
--    (reachable & usable) separately from in-transit and acquirable (e.g.
--    uncollected webs), so we no longer count silk still stuck in a web -- the
--    THREAD overcount that made the chain look unblocked when it was starved.
section('thread', function() report.thread = stock_states('THREAD') end)

-- 2. Cloth on hand (woven; the input to sewing clothes).
section('cloth', function() report.cloth = stock_states('CLOTH') end)

-- 3. Clothing on hand, by wear: item .wear runs 0 (new) .. 3 (tattered, about to
-- fall apart). Tattered/worn counts are the morale demand signal -- dwarves in
-- rotting clothes get unhappy, so a high tattered count means make replacements.
local CLOTHING = { 'ARMOR', 'PANTS', 'SHOES', 'GLOVES', 'HELM' }
section('clothing', function()
    local by_type, total, tattered, worn = {}, 0, 0, 0
    for _, tname in ipairs(CLOTHING) do
        local vec = world.items.other[tname]
        if vec then
            local c, t = 0, 0
            for _, it in ipairs(vec) do
                c = c + 1
                local w = it.wear or 0
                if w >= 3 then t = t + 1; tattered = tattered + 1 end
                if w >= 2 then worn = worn + 1 end
            end
            by_type[tname] = { count = c, tattered = t }
            total = total + c
        end
    end
    report.clothing = { by_type = by_type, total = total,
                        tattered = tattered, worn = worn }
end)

-- 4. Workstations: Looms (weave) and Clothier's shops (sew).
section('shops', function()
    local lc, lb = workshops_of(df.workshop_type.Loom)
    local cc, cb = workshops_of(df.workshop_type.Clothiers)
    report.looms = { count = lc, busy = lb }
    report.clothiers = { count = cc, busy = cb }
end)

-- 5. Manager orders along the chain: weaving and clothes-making.
section('orders', function()
    local clothes_jobs = {
        [df.job_type.MakeArmor] = true, [df.job_type.MakePants] = true,
        [df.job_type.MakeShoes] = true, [df.job_type.MakeGloves] = true,
        [df.job_type.MakeHelm] = true,
    }
    local weave_left, clothes_left = 0, 0
    for _, o in ipairs(world.manager_orders.all or world.manager_orders) do
        if o.job_type == df.job_type.WeaveCloth then
            weave_left = weave_left + o.amount_left
        elseif clothes_jobs[o.job_type] then
            clothes_left = clothes_left + o.amount_left
        end
    end
    report.orders = { weave_left = weave_left, clothes_left = clothes_left }
end)

finish()
