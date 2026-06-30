-- item_detail.lua
--
-- READ-ONLY deep inspection of ONE item by its id: type/subtype, material,
-- quality, wear, stack size, where it is (tile / container / carrier), the job
-- reserving it (if any), and its availability state (the classify_item verdict).
-- Generalizes the per-item slice artifact_locator.lua does for artifacts to any
-- item, so "what exactly is item #12345 and why isn't it usable" is answerable.
-- Mutates NOTHING.
--
-- Shared helpers (classify_item, item_subtype, matdesc, world, report, finish)
-- come from scripts/_prelude.lua, prepended by intel.py.
--
-- Args: item_id (a number)
-- Run via: RunCommand("lua", [<prelude + this file>, "12345"])

if not report.fort_loaded then finish() return end

local id = tonumber(select(1, ...) or '')
if not id then
    report.error = 'item id (a number) required'
    finish(); return
end

local it = df.item.find(id)
if not it then
    report.error = 'no item with id ' .. tostring(id)
    finish(); return
end

local d = { id = id }

-- Each field in its own pcall: a layout change on a future DF version drops one
-- field, never the whole report.
pcall(function() d.type = df.item_type[it:getType()] end)
pcall(function() d.subtype = item_subtype(it) end)
pcall(function() d.description = tostring(dfhack.items.getReadableDescription(it)) end)
pcall(function() d.material = matdesc(it) end)
pcall(function() d.stack_size = it.stack_size end)
pcall(function() d.quality = df.item_quality[it:getQuality()] end)
pcall(function() d.wear = it.wear end)

-- Availability verdict (reachable / forbidden / in_transit / carried / ...).
d.state = classify_item(it)

-- Position on the map (nil when held in a container or by a unit).
pcall(function()
    local x, y, z = dfhack.items.getPosition(it)
    if x then d.pos = { x = x, y = y, z = z } end
end)

-- Container it sits in, and/or the unit carrying it.
pcall(function()
    local cont = dfhack.items.getContainer(it)
    if cont then d.container = tostring(dfhack.items.getReadableDescription(cont)) end
end)
pcall(function()
    local u = dfhack.items.getHolderUnit(it)
    if u then d.holder = dfhack.units.getReadableName(u) end
end)

-- The job reserving this item, if any (a real job, or a hauling move).
pcall(function()
    if it.flags.in_job then
        local ref = dfhack.items.getSpecificRef(it, df.specific_ref_type.JOB)
        local job = ref and ref.data and ref.data.job
        if job then d.job = df.job_type[job.job_type] end
    end
end)

-- Notable flags worth surfacing for a "why isn't it usable" read.
d.flags = {}
for _, f in ipairs({ 'forbid', 'dump', 'melt', 'rotten', 'in_building',
                     'in_job', 'trader', 'spider_web' }) do
    pcall(function() if it.flags[f] then d.flags[#d.flags + 1] = f end end)
end

report.item = d
finish()
