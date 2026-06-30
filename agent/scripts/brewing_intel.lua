-- brewing_intel.lua
--
-- READ-ONLY fortress intelligence for beer/alcohol production.
-- Reads df.global.world state and prints a JSON report. Mutates NOTHING:
-- no assignments to game structures, no jobs created, no commands issued.
--
-- Run via: RunCommand("lua", [<contents of this file>]).
-- Each section is wrapped in pcall so a field-name change in a future DF
-- version degrades that one section instead of breaking the whole report;
-- failures are reported under "errors".

-- Shared helpers (section, matname, matdesc, world, report, finish...) come from
-- scripts/_prelude.lua, which intel.py prepends to this file.
if not report.fort_loaded then finish() return end

-- True if a container item currently holds nothing.
local function is_empty_container(it)
    for _, ref in ipairs(it.general_refs) do
        if ref:getType() == df.general_ref_type.CONTAINS_ITEM then
            return false
        end
    end
    return true
end

-- 1. Drinks on hand, by material, summed in units (stack_size).
section('drinks', function()
    local by_mat, total = {}, 0
    for _, it in ipairs(world.items.other.DRINK) do
        local n = it.stack_size
        total = total + n
        local key = matdesc(it)
        by_mat[key] = (by_mat[key] or 0) + n
    end
    report.drinks = { total_units = total, by_material = by_mat }
end)

-- 2. Empty containers available to hold freshly brewed drinks.
-- Barrels and large pots are counted separately so a failure in one does
-- not discard the other.
section('empty_barrels', function()
    local barrels = 0
    for _, it in ipairs(world.items.other.BARREL) do
        if is_available(it) and is_empty_container(it) then
            barrels = barrels + 1
        end
    end
    report.empty_containers = report.empty_containers or {}
    report.empty_containers.barrels = barrels
end)
section('empty_pots', function()
    -- isFoodStorage() identifies large pots usable for storing drinks.
    -- is_available() (not a bare forbid check) so a dumped / in-transit /
    -- stranded pot is not counted as ready-to-fill storage.
    local pots = 0
    for _, it in ipairs(world.items.other.TOOL) do
        if it:isFoodStorage() and is_available(it)
                and is_empty_container(it) then
            pots = pots + 1
        end
    end
    report.empty_containers = report.empty_containers or {}
    report.empty_containers.large_pots = pots
end)

-- 3. Brewable raw plant materials on hand (plump helmets etc.), by material.
section('plants', function()
    local by_mat, total = {}, 0
    for _, it in ipairs(world.items.other.PLANT) do
        local n = it.stack_size
        total = total + n
        local key = matdesc(it)
        by_mat[key] = (by_mat[key] or 0) + n
    end
    report.plants = { total_units = total, by_material = by_mat }
end)

-- 4. Still workshops: how many, and how many are busy with a job.
section('stills', function()
    local total, busy = 0, 0
    for _, b in ipairs(world.buildings.all) do
        if df.building_workshopst:is_instance(b)
                and b.type == df.workshop_type.Still then
            total = total + 1
            if #b.jobs > 0 then busy = busy + 1 end
        end
    end
    report.stills = { count = total, busy = busy }
end)

-- (Brewing is no longer a toggleable unit labor in DF v50+; it is governed
-- by work details, which are not cleanly enumerable here, so we do not
-- report a "brewers" count to avoid reporting something misleading.)

-- 5. Manager work orders for brewing drinks.
section('brew_orders', function()
    local orders = {}
    for _, o in ipairs(world.manager_orders.all or world.manager_orders) do
        if o.job_type == df.job_type.BrewDrink then
            orders[#orders + 1] = {
                amount_total = o.amount_total,
                amount_left = o.amount_left,
            }
        end
    end
    report.brew_orders = orders
end)

finish()
