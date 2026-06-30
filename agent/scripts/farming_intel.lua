-- farming_intel.lua
--
-- READ-ONLY fortress intelligence for the farming / crop industry.
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

local SEASONS = { [0] = 'spring', [1] = 'summer', [2] = 'autumn', [3] = 'winter' }

local function crop_name(plant_idx)
    local p = world.raws.plants.all[plant_idx]
    return (p and p.name) or ('plant#' .. tostring(plant_idx))
end

local season = df.global.cur_season
report.season = { index = season, name = SEASONS[season] or tostring(season) }

-- Seeds on hand, bucketed by crop, with a "free" count (not forbidden/carried).
-- Built first so the plots section can report seed availability per assigned crop.
local seeds_by = {}
section('seeds', function()
    local total, free_total = 0, 0
    for _, it in ipairs(world.items.other.SEEDS) do
        local n = it.stack_size
        total = total + n
        local name = crop_name(it.mat_index)
        local rec = seeds_by[name]
        if not rec then rec = { total = 0, free = 0 }; seeds_by[name] = rec end
        rec.total = rec.total + n
        if is_available(it) then
            rec.free = rec.free + n
            free_total = free_total + n
        end
    end
    report.seeds = { by_crop = seeds_by, total_units = total,
                     free_units = free_total }
end)

-- Farm plots: count, tiles, and what is assigned for the CURRENT season (the
-- only assignment that can plant right now). plant_id[season] is a plant raw
-- index, or -1 when nothing is assigned for that season.
section('plots', function()
    local plots, tiles_total = 0, 0
    local plots_with_crop, tiles_assigned = 0, 0
    local assigned = {}        -- crop name -> tiles assigned this season
    local active_plant, active_harvest = 0, 0
    for _, b in ipairs(world.buildings.all) do
        if df.building_farmplotst:is_instance(b) then
            plots = plots + 1
            local area = (b.x2 - b.x1 + 1) * (b.y2 - b.y1 + 1)
            tiles_total = tiles_total + area
            local pid = b.plant_id[season]
            if pid and pid >= 0 then
                plots_with_crop = plots_with_crop + 1
                tiles_assigned = tiles_assigned + area
                local name = crop_name(pid)
                assigned[name] = (assigned[name] or 0) + area
            end
            for _, j in ipairs(b.jobs) do
                if j.job_type == df.job_type.PlantSeeds then
                    active_plant = active_plant + 1
                elseif j.job_type == df.job_type.HarvestPlants then
                    active_harvest = active_harvest + 1
                end
            end
        end
    end

    -- Combine each assigned crop with whether seeds for it are on hand.
    local this_season = {}
    for name, tiles in pairs(assigned) do
        local sf = (seeds_by[name] and seeds_by[name].free) or 0
        this_season[name] = { tiles = tiles, seeds_free = sf }
    end

    report.plots = {
        count = plots,
        total_tiles = tiles_total,
        plots_with_crop_this_season = plots_with_crop,
        tiles_assigned_this_season = tiles_assigned,
        this_season = this_season,
        active_plant_jobs = active_plant,
        active_harvest_jobs = active_harvest,
    }
end)

finish()
