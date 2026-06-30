-- diagnose_farming.lua
--
-- READ-ONLY root-cause analysis for "why aren't crops being planted?".
-- Gathers the facts along the farming pipeline and runs a fixed set of
-- deterministic checks, each marked ok/not-ok with a short detail. The caller
-- (Python formatter + the assistant) ranks and narrates from these. Hybrid by
-- design: the script states facts, the reader reasons. Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

-- Shared helpers (add, is_available, world, report, finish...) come from
-- scripts/_prelude.lua, which intel.py prepends to this file.
if not report.fort_loaded then finish() return end
report.target = 'planted crops'
report.facts = {}

local SEASONS = { [0] = 'spring', [1] = 'summer', [2] = 'autumn', [3] = 'winter' }
local function crop_name(plant_idx)
    local p = world.raws.plants.all[plant_idx]
    return (p and p.name) or ('plant#' .. tostring(plant_idx))
end

local season = df.global.cur_season
report.facts.season = SEASONS[season] or tostring(season)

-- Free seeds on hand, by crop (for matching against assigned crops below).
local seed_free = {}
pcall(function()
    for _, it in ipairs(world.items.other.SEEDS) do
        if is_available(it) then
            local name = crop_name(it.mat_index)
            seed_free[name] = (seed_free[name] or 0) + it.stack_size
        end
    end
end)

-- 1. Are there any farm plots, and what is assigned for the current season?
local plots, plots_with_crop = 0, 0
local assigned, missing_seed = {}, {}
local active_plant = 0
pcall(function()
    for _, b in ipairs(world.buildings.all) do
        if df.building_farmplotst:is_instance(b) then
            plots = plots + 1
            local pid = b.plant_id[season]
            if pid and pid >= 0 then
                plots_with_crop = plots_with_crop + 1
                local name = crop_name(pid)
                assigned[name] = true
                if (seed_free[name] or 0) == 0 then
                    missing_seed[name] = true
                end
            end
            for _, j in ipairs(b.jobs) do
                if j.job_type == df.job_type.PlantSeeds then
                    active_plant = active_plant + 1
                end
            end
        end
    end
end)
report.facts.farm_plots = plots
report.facts.plots_with_crop_this_season = plots_with_crop
report.facts.active_plant_jobs = active_plant
add('farm_plot_exists', plots > 0, 'blocker', plots .. ' farm plot(s) built')
add('crop_assigned', plots_with_crop > 0, 'blocker',
    plots_with_crop .. ' plot(s) have a crop set for ' ..
    (SEASONS[season] or '?'))

-- 2. Of the crops assigned this season, are seeds on hand for at least one?
local assigned_n, with_seed, missing_list = 0, 0, {}
for name in pairs(assigned) do
    assigned_n = assigned_n + 1
    if (seed_free[name] or 0) > 0 then with_seed = with_seed + 1 end
end
for name in pairs(missing_seed) do missing_list[#missing_list + 1] = name end
report.facts.assigned_crops = assigned_n
report.facts.assigned_crops_with_seed = with_seed
if assigned_n == 0 then
    add('seeds_available', nil, 'blocker',
        'no crop assigned this season, so seed need is undetermined')
else
    local detail = with_seed .. ' of ' .. assigned_n ..
        ' assigned crop(s) have seeds on hand'
    if #missing_list > 0 then
        detail = detail .. ' (no seeds: ' .. table.concat(missing_list, ', ') .. ')'
    end
    add('seeds_available', with_seed > 0, 'blocker', detail)
end

-- 3. Is anyone able/assigned to farm? Like other v50+ labors this is governed
-- by work details, not a toggleable labor. A labor with NO work detail is done
-- by everyone by default; a labor governed by a detail with nobody assigned is
-- a real blocker. The farming (fields) labor is PLANT.
local plant_labor_known = false
local wd_count, wd_units = 0, 0
local labor_eval_ok = pcall(function()
    plant_labor_known = (df.unit_labor.PLANT ~= nil)
    local details = df.global.plotinfo.labor_info.work_details
    for _, wd in ipairs(details) do
        local allows = false
        pcall(function() allows = wd.allowed_labors.PLANT end)
        if allows then
            wd_count = wd_count + 1
            wd_units = wd_units + #wd.assigned_units
        end
    end
end)
report.facts.plant_labor_known = plant_labor_known
report.facts.farm_work_details = wd_count
report.facts.farm_work_detail_units = wd_units
if not labor_eval_ok then
    add('planter_assigned', nil, 'blocker',
        'could not read work details on this DF version; check manually')
elseif wd_count == 0 then
    add('planter_assigned', true, 'blocker',
        'no work detail restricts farming; any able dwarf can plant')
elseif wd_units == 0 then
    add('planter_assigned', false, 'blocker',
        wd_count .. ' work detail(s) govern farming but no dwarf is assigned')
else
    add('planter_assigned', true, 'blocker',
        wd_units .. ' dwarf(s) assigned to farm via work details')
end

add('planting_active', active_plant > 0, 'info',
    active_plant .. ' planting job(s) currently queued at plots')

finish()
