-- cooking_intel.lua
--
-- READ-ONLY fortress intelligence for the kitchen / cooking industry.
-- Reads df.global.world state and prints a JSON report. Mutates NOTHING:
-- no assignments to game structures, no jobs created, no commands issued.
--
-- Run via: RunCommand("lua", [<contents of this file>]).
-- Each section is wrapped in pcall so a field-name change in a future DF
-- version degrades that one section instead of breaking the whole report;
-- failures are reported under "errors".

-- Shared helpers (section, is_available, world, report, finish...) come from
-- scripts/_prelude.lua, which intel.py prepends to this file.
if not report.fort_loaded then finish() return end

-- Item-type buckets that "Prepare Meal" can consume. world.items.other is keyed
-- by item-type name; an unknown/absent key just yields nil and is skipped.
local COOKABLE = {
    'MEAT', 'FISH', 'EGG', 'CHEESE', 'PLANT', 'PLANT_GROWTH',
    'GLOB', 'POWDER_MISC', 'LIQUID_MISC',
}

-- 1. Prepared meals on hand (item type FOOD), summed in units (stack_size).
section('meals', function()
    local total = 0
    for _, it in ipairs(world.items.other.FOOD) do
        total = total + it.stack_size
    end
    report.meals = { total_units = total }
end)

-- 2. Raw cookable ingredients on hand, bucketed by item type, with a "free"
-- count (not forbidden, not carried, not rotten) and how many distinct types
-- are available -- a meal needs >= 2 distinct ingredients.
section('ingredients', function()
    local by_type, total, free_total, distinct_free = {}, 0, 0, 0
    for _, tname in ipairs(COOKABLE) do
        local vec = world.items.other[tname]
        if vec then
            local units, free = 0, 0
            for _, it in ipairs(vec) do
                local n = it.stack_size
                units = units + n
                if is_available(it) then free = free + n end
            end
            if units > 0 then
                by_type[tname] = { units = units, free = free }
                total = total + units
                free_total = free_total + free
                if free > 0 then distinct_free = distinct_free + 1 end
            end
        end
    end
    report.ingredients = {
        by_type = by_type,
        total_units = total,
        free_units = free_total,
        distinct_free_types = distinct_free,
    }
end)

-- 3. Kitchen workshops: how many, and how many are busy with a job.
section('kitchens', function()
    local total, busy = 0, 0
    for _, b in ipairs(world.buildings.all) do
        if df.building_workshopst:is_instance(b)
                and b.type == df.workshop_type.Kitchen then
            total = total + 1
            if #b.jobs > 0 then busy = busy + 1 end
        end
    end
    report.kitchens = { count = total, busy = busy }
end)

-- 4. Manager work orders for preparing meals.
section('cook_orders', function()
    local orders = {}
    for _, o in ipairs(world.manager_orders.all or world.manager_orders) do
        if o.job_type == df.job_type.PrepareMeal then
            orders[#orders + 1] = {
                amount_total = o.amount_total,
                amount_left = o.amount_left,
            }
        end
    end
    report.cook_orders = orders
end)

finish()
