-- diagnose_cooking.lua
--
-- READ-ONLY root-cause analysis for "why is nobody cooking meals?".
-- Gathers the facts along the cooking pipeline and runs a fixed set of
-- deterministic checks, each marked ok/not-ok with a short detail. The caller
-- (Python formatter + the assistant) ranks and narrates from these. Hybrid by
-- design: the script states facts, the reader reasons. Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

-- Shared helpers (add, is_available, world, report, finish...) come from
-- scripts/_prelude.lua, which intel.py prepends to this file.
if not report.fort_loaded then finish() return end
report.target = 'prepared meals'
report.facts = {}

local COOKABLE = {
    'MEAT', 'FISH', 'EGG', 'CHEESE', 'PLANT', 'PLANT_GROWTH',
    'GLOB', 'POWDER_MISC', 'LIQUID_MISC',
}

-- 1. Is there an active prepare-meal order with work remaining?
local order_left = 0
pcall(function()
    for _, o in ipairs(world.manager_orders.all or world.manager_orders) do
        if o.job_type == df.job_type.PrepareMeal then
            order_left = order_left + o.amount_left
        end
    end
end)
report.facts.cook_order_units_left = order_left
add('cook_order_exists', order_left > 0, 'blocker',
    order_left .. ' meal(s) still queued across cook orders')

-- 2. Is there at least one Kitchen, and is one free / already cooking?
local kitchens, kitchens_idle, active_cook_jobs = 0, 0, 0
pcall(function()
    for _, b in ipairs(world.buildings.all) do
        if df.building_workshopst:is_instance(b)
                and b.type == df.workshop_type.Kitchen then
            kitchens = kitchens + 1
            if #b.jobs == 0 then kitchens_idle = kitchens_idle + 1 end
            for _, j in ipairs(b.jobs) do
                if j.job_type == df.job_type.PrepareMeal then
                    active_cook_jobs = active_cook_jobs + 1
                end
            end
        end
    end
end)
report.facts.kitchens = kitchens
report.facts.kitchens_idle = kitchens_idle
report.facts.active_cook_jobs = active_cook_jobs
add('kitchen_exists', kitchens > 0, 'blocker', kitchens .. ' kitchen(s) built')
add('cook_job_running', active_cook_jobs > 0, 'info',
    active_cook_jobs .. ' cook job(s) currently queued at a kitchen')

-- 3. Cookable ingredients on hand, and how many distinct types are available.
-- A meal requires at least 2 distinct ingredients, so variety is its own check.
local ing_free, distinct_free = 0, 0
pcall(function()
    for _, tname in ipairs(COOKABLE) do
        local vec = world.items.other[tname]
        if vec then
            local free = 0
            for _, it in ipairs(vec) do
                if is_available(it) then free = free + it.stack_size end
            end
            ing_free = ing_free + free
            if free > 0 then distinct_free = distinct_free + 1 end
        end
    end
end)
report.facts.ingredient_units_free = ing_free
report.facts.distinct_ingredient_types = distinct_free
add('ingredients_available', ing_free > 0, 'blocker',
    ing_free .. ' unforbidden cookable ingredient unit(s) on hand')
add('ingredient_variety', distinct_free >= 2, 'blocker',
    distinct_free .. ' distinct ingredient type(s) free (a meal needs >= 2)')

-- 4. Is anyone able/assigned to cook? Like brewing, DF v50+ governs this with
-- work details, not a toggleable labor. A labor with NO work detail is done by
-- everyone by default; a labor governed by a detail with nobody assigned is a
-- real blocker. We surface both facts and let the check reflect that nuance.
local cook_labor_known = false
local wd_cook_count, wd_cook_units = 0, 0
local labor_eval_ok = pcall(function()
    cook_labor_known = (df.unit_labor.COOK ~= nil)
    local details = df.global.plotinfo.labor_info.work_details
    for _, wd in ipairs(details) do
        local allows = false
        pcall(function() allows = wd.allowed_labors.COOK end)
        if allows then
            wd_cook_count = wd_cook_count + 1
            wd_cook_units = wd_cook_units + #wd.assigned_units
        end
    end
end)
report.facts.cook_labor_known = cook_labor_known
report.facts.cook_work_details = wd_cook_count
report.facts.cook_work_detail_units = wd_cook_units
if not labor_eval_ok then
    add('cook_assigned', nil, 'blocker',
        'could not read work details on this DF version; check manually')
elseif wd_cook_count == 0 then
    add('cook_assigned', true, 'blocker',
        'no work detail restricts cooking; any able dwarf can cook')
elseif wd_cook_units == 0 then
    add('cook_assigned', false, 'blocker',
        wd_cook_count .. ' work detail(s) govern cooking but no dwarf is assigned')
else
    add('cook_assigned', true, 'blocker',
        wd_cook_units .. ' dwarf(s) assigned to cook via work details')
end

finish()
