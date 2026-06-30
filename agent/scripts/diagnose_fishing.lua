-- diagnose_fishing.lua
--
-- READ-ONLY root-cause analysis for "why isn't fish food being produced?".
-- Gathers the facts along the fishing pipeline (catch raw fish -> clean at a
-- fishery -> edible fish) and runs a fixed set of deterministic checks, each
-- marked ok/not-ok with a short detail. The caller (Python formatter + the
-- assistant) ranks and narrates from these. Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

-- Shared helpers (add, is_available, labor_check, world, report, finish...) come
-- from scripts/_prelude.lua, which intel.py prepends to this file.
if not report.fort_loaded then finish() return end
report.target = 'edible fish'
report.facts = {}

-- 1. Is there a fishery to clean raw fish at, and is one free?
local fisheries, fisheries_idle, active_clean = 0, 0, 0
pcall(function()
    for _, b in ipairs(world.buildings.all) do
        if df.building_workshopst:is_instance(b)
                and b.type == df.workshop_type.Fishery then
            fisheries = fisheries + 1
            if #b.jobs == 0 then fisheries_idle = fisheries_idle + 1 end
            for _, j in ipairs(b.jobs) do
                if j.job_type == df.job_type.PrepareRawFish then
                    active_clean = active_clean + 1
                end
            end
        end
    end
end)
report.facts.fisheries = fisheries
report.facts.fisheries_idle = fisheries_idle
report.facts.active_clean_jobs = active_clean
add('fishery_exists', fisheries > 0, 'blocker', fisheries .. ' fishery(ies) built')

-- 2. Fish on hand: edible and raw-waiting.
local edible, raw_free = 0, 0
pcall(function()
    for _, it in ipairs(world.items.other.FISH) do edible = edible + it.stack_size end
end)
pcall(function()
    for _, it in ipairs(world.items.other.FISH_RAW) do
        if is_available(it) then raw_free = raw_free + it.stack_size end
    end
end)
report.facts.edible_fish = edible
report.facts.raw_fish_free = raw_free
add('raw_fish_processing', nil, 'info',
    raw_free .. ' raw fish waiting, ' .. active_clean .. ' clean job(s) active, '
    .. edible .. ' edible fish on hand')

-- 3. Is anyone assigned to catch fish (FISH labor)?
local fish_ok, fish_detail = labor_check('FISH')
add('fisher_assigned', fish_ok, 'blocker', 'catch (FISH): ' .. fish_detail)

-- 4. Is anyone assigned to clean fish (CLEAN_FISH labor)?
local clean_ok, clean_detail = labor_check('CLEAN_FISH')
add('cleaner_assigned', clean_ok, 'blocker', 'clean (CLEAN_FISH): ' .. clean_detail)

-- 5. Fishable water can't be reliably detected from here; flag for manual check.
add('fishable_water', nil, 'info',
    'accessible fishable water is not reliably detectable here; verify a fishing '
    .. 'zone over water with a fish population if no raw fish are ever caught')

finish()
