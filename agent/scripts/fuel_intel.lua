-- fuel_intel.lua
--
-- READ-ONLY fortress intelligence for the fuel industry (wood -> charcoal at a
-- Wood Furnace; coal -> coke at a Smelter). Fuel feeds smelting, forging and
-- glassmaking. Mutates NOTHING. Shared helpers come from scripts/_prelude.lua.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end

-- 1. Fuel on hand (charcoal/coke/coal bars), by material.
section('fuel', function()
    local total, free, by_mat = 0, 0, {}
    for _, it in ipairs(world.items.other.BAR) do
        local name = matdesc(it)
        local n = (name or ''):lower()
        if n:find('charcoal') or n:find('coke') or n == 'coal' then
            local q = it.stack_size
            total = total + q
            by_mat[name] = (by_mat[name] or 0) + q
            if is_available(it) then free = free + q end
        end
    end
    report.fuel = { total_units = total, free_units = free, by_material = by_mat }
end)

-- 2. Logs on hand (charcoal input).
section('wood', function()
    local total, free = 0, 0
    for _, it in ipairs(world.items.other.WOOD) do
        total = total + it.stack_size
        if is_available(it) then free = free + it.stack_size end
    end
    report.wood = { total_units = total, free_units = free }
end)

-- 3. Wood furnaces (make charcoal) and magma alternatives (which make fuel
-- optional for smelting/forging).
section('shops', function()
    local wc, wb = furnaces_of(df.furnace_type.WoodFurnace)
    local mc = ({ furnaces_of(df.furnace_type.MagmaSmelter) })[1]
    local mg = ({ workshops_of(df.workshop_type.MagmaForge) })[1]
    report.wood_furnaces = { count = wc, busy = wb }
    report.magma = { smelters = mc, forges = mg }
end)

-- 4. Manager orders for making charcoal.
section('orders', function()
    local left = 0
    for _, o in ipairs(world.manager_orders.all or world.manager_orders) do
        if o.job_type == df.job_type.MakeCharcoal then
            left = left + o.amount_left
        end
    end
    report.charcoal_orders_left = left
end)

finish()
