-- diagnose_butchery.lua
--
-- READ-ONLY root-cause analysis for "why isn't anything being butchered?".
-- Gathers the facts along the butchery pipeline (animal flagged for slaughter ->
-- butcher's shop built/free -> a dwarf able to butcher -> meat/leather) and runs
-- a fixed set of deterministic checks, each marked ok/not-ok with a short detail.
-- Tanning is reported as secondary context. Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

-- Shared helpers (add, labor_check, world, report, finish...) come from
-- scripts/_prelude.lua, which intel.py prepends to this file.
if not report.fort_loaded then finish() return end
report.target = 'butchered meat'
report.facts = {}

-- 1. Is there a Butcher's shop, and is one free?
local shops, shops_idle, active_butcher = 0, 0, 0
pcall(function()
    for _, b in ipairs(world.buildings.all) do
        if df.building_workshopst:is_instance(b)
                and b.type == df.workshop_type.Butchers then
            shops = shops + 1
            if #b.jobs == 0 then shops_idle = shops_idle + 1 end
            for _, j in ipairs(b.jobs) do
                if j.job_type == df.job_type.ButcherAnimal then
                    active_butcher = active_butcher + 1
                end
            end
        end
    end
end)
report.facts.butcher_shops = shops
report.facts.butcher_shops_idle = shops_idle
report.facts.active_butcher_jobs = active_butcher
add('butcher_shop_exists', shops > 0, 'blocker', shops .. " butcher's shop(s) built")

-- 2. Is there anything to butcher? (animals marked for slaughter + corpses)
local marked, corpses = 0, 0
pcall(function()
    for _, u in ipairs(world.units.active) do
        local s = false
        pcall(function() s = u.flags2.slaughter end)
        if s then marked = marked + 1 end
    end
end)
pcall(function()
    local v = world.items.other.CORPSE
    corpses = v and #v or 0
end)
report.facts.marked_for_slaughter = marked
report.facts.corpses = corpses
add('something_to_butcher', (marked + corpses) > 0, 'blocker',
    marked .. ' animal(s) marked for slaughter, ' .. corpses .. ' corpse(s) present')

-- 3. Is anyone assigned to butcher (BUTCHER labor)?
local butcher_ok, butcher_detail = labor_check('BUTCHER')
add('butcher_assigned', butcher_ok, 'blocker', 'butcher (BUTCHER): ' .. butcher_detail)

-- 4. Tanning context (secondary): tannery built + a tanner assigned. Leather is
-- a downstream product, so these are info, not blockers for meat.
local tanneries = 0
pcall(function()
    for _, b in ipairs(world.buildings.all) do
        if df.building_workshopst:is_instance(b)
                and b.type == df.workshop_type.Tanners then
            tanneries = tanneries + 1
        end
    end
end)
report.facts.tanneries = tanneries
report.facts.leather_units = (function()
    local v = world.items.other.SKIN_TANNED
    local t = 0
    if v then for _, it in ipairs(v) do
        if is_available(it) then t = t + it.stack_size end
    end end
    return t
end)()
add('tannery_exists', tanneries > 0, 'info', tanneries .. " tanner's shop(s) built")
local tanner_ok, tanner_detail = labor_check('TANNER')
add('tanner_assigned', tanner_ok, 'info', 'tan (TANNER): ' .. tanner_detail)

finish()
