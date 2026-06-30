-- fishing_intel.lua
--
-- READ-ONLY fortress intelligence for the fishing industry.
-- Reads df.global.world state and prints a JSON report. Mutates NOTHING:
-- no assignments to game structures, no jobs created, no commands issued.
--
-- Run via: RunCommand("lua", [<contents of this file>]).
-- Each section is wrapped in pcall so a field-name change in a future DF
-- version degrades that one section instead of breaking the whole report;
-- failures are reported under "errors".

-- Shared helpers (section, matdesc, is_available, world, report, finish...) come
-- from scripts/_prelude.lua, which intel.py prepends to this file.
if not report.fort_loaded then finish() return end

-- 1. Edible (cleaned) fish on hand, by material, summed in units. matdesc()
-- decodes the item directly, so creature-derived fish materials resolve.
section('fish', function()
    local total, by_mat = 0, {}
    for _, it in ipairs(world.items.other.FISH) do
        local n = it.stack_size
        total = total + n
        local key = matdesc(it)
        by_mat[key] = (by_mat[key] or 0) + n
    end
    report.fish = { total_units = total, by_material = by_mat }
end)

-- 2. Raw fish waiting to be cleaned at a fishery (intermediate product).
section('raw_fish', function()
    local total, free = 0, 0
    for _, it in ipairs(world.items.other.FISH_RAW) do
        local n = it.stack_size
        total = total + n
        if is_available(it) then free = free + n end
    end
    report.raw_fish = { total_units = total, free_units = free }
end)

-- 3. Fishery workshops: how many, and how many are busy with a job.
section('fisheries', function()
    local total, busy = 0, 0
    for _, b in ipairs(world.buildings.all) do
        if df.building_workshopst:is_instance(b)
                and b.type == df.workshop_type.Fishery then
            total = total + 1
            if #b.jobs > 0 then busy = busy + 1 end
        end
    end
    report.fisheries = { count = total, busy = busy }
end)

-- 4. Manager work orders for preparing (cleaning) raw fish.
section('clean_orders', function()
    local orders = {}
    for _, o in ipairs(world.manager_orders.all or world.manager_orders) do
        if o.job_type == df.job_type.PrepareRawFish then
            orders[#orders + 1] = {
                amount_total = o.amount_total,
                amount_left = o.amount_left,
            }
        end
    end
    report.clean_orders = orders
end)

finish()
