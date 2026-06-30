-- construction_intel.lua
--
-- READ-ONLY fortress intelligence for the building-materials industries:
-- masonry (stone -> blocks/furniture), carpentry (logs -> furniture),
-- glass (sand+fuel -> raw glass), and mechanisms (stone -> mechanisms).
-- Mutates NOTHING. Shared helpers (section, is_available, furnaces_of,
-- workshops_of, world, report, finish...) come from scripts/_prelude.lua.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end

-- Free + total stack units of an item type.
local function stock(tname)
    local total, free = 0, 0
    local vec = world.items.other[tname]
    if vec then
        for _, it in ipairs(vec) do
            total = total + it.stack_size
            if is_available(it) then free = free + it.stack_size end
        end
    end
    return { total_units = total, free_units = free }
end

-- 1. Masonry: Mason's shops, blocks on hand, stone (boulders) to cut.
section('masonry', function()
    local c, b = workshops_of(df.workshop_type.Masons)
    report.masonry = { shops = c, busy = b,
                       blocks = stock('BLOCKS'), stone = stock('BOULDER') }
end)

-- 2. Carpentry: Carpenter's shops, logs to build with.
section('carpentry', function()
    local c, b = workshops_of(df.workshop_type.Carpenters)
    report.carpentry = { shops = c, busy = b, logs = stock('WOOD') }
end)

-- 3. Glass: glass furnaces (regular + magma), raw glass (ROUGH) on hand.
section('glass', function()
    local gc, gb = furnaces_of(df.furnace_type.GlassFurnace)
    local mc, mb = furnaces_of(df.furnace_type.MagmaGlassFurnace)
    report.glass = { furnaces = gc + mc, busy = gb + mb, magma = mc,
                     raw_glass = stock('ROUGH') }
end)

-- 4. Mechanisms: Mechanic's shops, mechanisms (TRAPPARTS) on hand, stone input.
section('mechanisms', function()
    local c, b = workshops_of(df.workshop_type.Mechanics)
    report.mechanisms = { shops = c, busy = b,
                          mechanisms = stock('TRAPPARTS'),
                          stone = stock('BOULDER') }
end)

-- 5. Manager orders across these chains.
section('orders', function()
    local left = { blocks = 0, mechanisms = 0, glass = 0 }
    for _, o in ipairs(world.manager_orders.all or world.manager_orders) do
        if o.job_type == df.job_type.ConstructBlocks then
            left.blocks = left.blocks + o.amount_left
        elseif o.job_type == df.job_type.ConstructMechanisms then
            left.mechanisms = left.mechanisms + o.amount_left
        elseif o.job_type == df.job_type.MakeRawGlass then
            left.glass = left.glass + o.amount_left
        end
    end
    report.orders = left
end)

finish()
