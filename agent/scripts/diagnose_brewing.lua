-- diagnose_brewing.lua
--
-- READ-ONLY root-cause analysis for "why is nobody making beer?".
-- Gathers the facts along the brewing pipeline and runs a fixed set of
-- deterministic checks, each marked ok/not-ok with a short detail. The caller
-- (Python formatter + the assistant) ranks and narrates from these. Hybrid by
-- design: the script states facts, the reader reasons. Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

-- Shared helpers (add, is_available, section, world, report, finish...) come
-- from scripts/_prelude.lua, which intel.py prepends to this file.
if not report.fort_loaded then finish() return end
report.target = 'beer'
report.facts = {}

local function is_empty_container(it)
    for _, ref in ipairs(it.general_refs) do
        if ref:getType() == df.general_ref_type.CONTAINS_ITEM then
            return false
        end
    end
    return true
end

-- 1. Is there an active brew order with work remaining?
local order_left = 0
pcall(function()
    local list = world.manager_orders.all or world.manager_orders
    for _, o in ipairs(list) do
        if o.job_type == df.job_type.BrewDrink
                or (df.job_type[o.job_type] == 'CustomReaction'
                    and o.reaction_name and o.reaction_name:match('^BREW_')) then
            order_left = order_left + o.amount_left
        end
    end
end)
report.facts.brew_order_units_left = order_left
add('brew_order_exists', order_left > 0, 'blocker',
    order_left .. ' drink(s) still queued across brew orders')

-- 2. Is there at least one Still, and is one free / already brewing?
local stills, stills_idle, active_brew_jobs = 0, 0, 0
pcall(function()
    for _, b in ipairs(world.buildings.all) do
        if df.building_workshopst:is_instance(b)
                and b.type == df.workshop_type.Still then
            stills = stills + 1
            if #b.jobs == 0 then stills_idle = stills_idle + 1 end
            for _, j in ipairs(b.jobs) do
                if j.job_type == df.job_type.BrewDrink then
                    active_brew_jobs = active_brew_jobs + 1
                end
            end
        end
    end
end)
report.facts.stills = stills
report.facts.stills_idle = stills_idle
report.facts.active_brew_jobs = active_brew_jobs
add('still_exists', stills > 0, 'blocker', stills .. ' still(s) built')
add('brew_job_running', active_brew_jobs > 0, 'info',
    active_brew_jobs .. ' brew job(s) currently queued at a still')

-- 3. Raw plants on hand to brew (heuristic: most PLANT items are brewable).
local plant_units, plant_free = 0, 0
pcall(function()
    for _, it in ipairs(world.items.other.PLANT) do
        plant_units = plant_units + it.stack_size
        if is_available(it) then
            plant_free = plant_free + it.stack_size
        end
    end
end)
report.facts.raw_plant_units = plant_units
report.facts.raw_plant_units_free = plant_free
add('brewable_plants_available', plant_free > 0, 'blocker',
    plant_free .. ' unforbidden raw plant unit(s) on hand (most are brewable)')

-- 4. Empty container to hold the finished drink.
local empty_barrels, empty_pots = 0, 0
-- is_available() (not a bare forbid check) so a barrel that's dumped, being
-- hauled, or stranded in the caverns doesn't count as ready-to-fill storage.
pcall(function()
    for _, it in ipairs(world.items.other.BARREL) do
        if is_available(it) and is_empty_container(it) then
            empty_barrels = empty_barrels + 1
        end
    end
end)
pcall(function()
    for _, it in ipairs(world.items.other.TOOL) do
        if it:isFoodStorage() and is_available(it)
                and is_empty_container(it) then
            empty_pots = empty_pots + 1
        end
    end
end)
report.facts.empty_barrels = empty_barrels
report.facts.empty_pots = empty_pots
add('empty_container_available', (empty_barrels + empty_pots) > 0, 'blocker',
    empty_barrels .. ' empty barrel(s), ' .. empty_pots .. ' empty large pot(s)')

-- 5. Is anyone able/assigned to brew? In DF v50+ this is governed by work
-- details, not a toggleable labor. A labor with NO work detail is done by
-- everyone by default; a labor governed by a detail with nobody assigned is a
-- real blocker. We surface both facts and let the check reflect that nuance.
local brew_labor_known = false
local wd_brew_count, wd_brew_units = 0, 0
local labor_eval_ok = pcall(function()
    -- The brewing labor is BREWER in DF v50+ (not BREW/BREWING).
    brew_labor_known = (df.unit_labor.BREWER ~= nil)
    local details = df.global.plotinfo.labor_info.work_details
    for _, wd in ipairs(details) do
        local allows = false
        pcall(function() allows = wd.allowed_labors.BREWER end)
        if allows then
            wd_brew_count = wd_brew_count + 1
            wd_brew_units = wd_brew_units + #wd.assigned_units
        end
    end
end)
report.facts.brew_labor_known = brew_labor_known
report.facts.brew_work_details = wd_brew_count
report.facts.brew_work_detail_units = wd_brew_units
if not labor_eval_ok then
    add('brewer_assigned', nil, 'blocker',
        'could not read work details on this DF version; check manually')
elseif wd_brew_count == 0 then
    add('brewer_assigned', true, 'blocker',
        'no work detail restricts brewing; any able dwarf can brew')
elseif wd_brew_units == 0 then
    add('brewer_assigned', false, 'blocker',
        wd_brew_count .. ' work detail(s) govern brewing but no dwarf is assigned')
else
    add('brewer_assigned', true, 'blocker',
        wd_brew_units .. ' dwarf(s) assigned to brew via work details')
end

finish()
