-- butchery_intel.lua
--
-- READ-ONLY fortress intelligence for the butchery (and tanning) industry.
-- Reads df.global.world state and prints a JSON report. Mutates NOTHING:
-- no assignments to game structures, no jobs created, no commands issued.
--
-- Run via: RunCommand("lua", [<contents of this file>]).
-- Each section is wrapped in pcall so a field-name change in a future DF
-- version degrades that one section instead of breaking the whole report;
-- failures are reported under "errors".

-- Shared helpers (section, world, report, finish...) come from
-- scripts/_prelude.lua, which intel.py prepends to this file.
if not report.fort_loaded then finish() return end

-- Available (reachable & usable) units only -- raw totals counted forbidden,
-- rotten, and stranded-in-the-caverns meat/fat/leather as on-hand.
local function units_of(tname)
    local v = world.items.other[tname]
    local total = 0
    if v then for _, it in ipairs(v) do
        if is_available(it) then total = total + it.stack_size end
    end end
    return total
end

-- 1. Animals queued for slaughter (the input that drives butchering).
section('slaughter', function()
    local marked = 0
    for _, u in ipairs(world.units.active) do
        local s = false
        pcall(function() s = u.flags2.slaughter end)
        if s then marked = marked + 1 end
    end
    report.marked_for_slaughter = marked
end)

-- 2. Butcherable corpses lying around (also butchered at a Butcher's shop).
section('corpses', function()
    local v = world.items.other.CORPSE
    local n = 0
    if v then for _, it in ipairs(v) do
        if is_available(it) then n = n + 1 end
    end end
    report.corpses = n
end)

-- 3. Butcher's shops: how many, and how many are busy.
section('butcher_shops', function()
    local total, busy = 0, 0
    for _, b in ipairs(world.buildings.all) do
        if df.building_workshopst:is_instance(b)
                and b.type == df.workshop_type.Butchers then
            total = total + 1
            if #b.jobs > 0 then busy = busy + 1 end
        end
    end
    report.butcher_shops = { count = total, busy = busy }
end)

-- 4. Butchery output on hand: meat and fat/tallow (GLOB).
section('output', function()
    report.output = { meat = units_of('MEAT'), fat = units_of('GLOB') }
end)

-- 5. Tanning (secondary): Tanner's shops + leather on hand. Raw hides are not a
-- distinct item type in this DF version, so they are not counted here.
section('tanning', function()
    local total, busy = 0, 0
    for _, b in ipairs(world.buildings.all) do
        if df.building_workshopst:is_instance(b)
                and b.type == df.workshop_type.Tanners then
            total = total + 1
            if #b.jobs > 0 then busy = busy + 1 end
        end
    end
    report.tanning = {
        tanneries = { count = total, busy = busy },
        leather_units = units_of('SKIN_TANNED'),
    }
end)

-- 6. Manager work orders for butchering (usually butchering is automatic, so
-- this is often empty -- included for completeness).
section('butcher_orders', function()
    local orders = {}
    for _, o in ipairs(world.manager_orders.all or world.manager_orders) do
        if o.job_type == df.job_type.ButcherAnimal then
            orders[#orders + 1] = {
                amount_total = o.amount_total,
                amount_left = o.amount_left,
            }
        end
    end
    report.butcher_orders = orders
end)

finish()
