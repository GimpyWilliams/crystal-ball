-- metal_intel.lua
--
-- READ-ONLY fortress intelligence for the metal industry (ore -> bars at a
-- Smelter -> goods at a Forge). Mutates NOTHING. Shared helpers (section,
-- matdesc, is_available, furnaces_of, workshops_of, world, report, finish...)
-- come from scripts/_prelude.lua, prepended by intel.py.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end

-- A boulder is metal ore if its inorganic material carries the METAL_ORE flag.
local function is_ore(it)
    local mi = dfhack.matinfo.decode(it)
    if mi and mi.inorganic then
        local ok, v = pcall(function() return mi.inorganic.flags.METAL_ORE end)
        return ok and v == true
    end
    return false
end

-- Classify a BAR by its material name: fuel (charcoal/coke/coal), byproduct
-- (ash/potash), or metal (everything else).
local function bar_class(name)
    local n = (name or ''):lower()
    if n:find('charcoal') or n:find('coke') or n == 'coal' then return 'fuel' end
    if n == 'ash' or n == 'potash' then return 'byproduct' end
    return 'metal'
end

-- 1. Metal ore on hand (boulders flagged METAL_ORE), by material.
section('ore', function()
    local total, free, by_mat = 0, 0, {}
    for _, it in ipairs(world.items.other.BOULDER) do
        if is_ore(it) then
            local n = it.stack_size
            total = total + n
            by_mat[matdesc(it)] = (by_mat[matdesc(it)] or 0) + n
            if is_available(it) then free = free + n end
        end
    end
    report.ore = { total_units = total, free_units = free, by_material = by_mat }
end)

-- 2. Bars on hand, split into metal (by material) and fuel.
section('bars', function()
    local metal_by, metal_free, fuel_units = {}, 0, 0
    for _, it in ipairs(world.items.other.BAR) do
        local name = matdesc(it)
        local cls = bar_class(name)
        local n = it.stack_size
        if cls == 'metal' then
            metal_by[name] = (metal_by[name] or 0) + n
            if is_available(it) then metal_free = metal_free + n end
        elseif cls == 'fuel' then
            fuel_units = fuel_units + n
        end
    end
    report.bars = { metal_by_material = metal_by, metal_free = metal_free,
                    fuel_units = fuel_units }
end)

-- 3. Smelters (regular + magma) and forges (regular + magma).
section('shops', function()
    local sc, sb = furnaces_of(df.furnace_type.Smelter)
    local mc, mb = furnaces_of(df.furnace_type.MagmaSmelter)
    local fc, fb = workshops_of(df.workshop_type.MetalsmithsForge)
    local gc, gb = workshops_of(df.workshop_type.MagmaForge)
    report.smelters = { count = sc + mc, busy = sb + mb, magma = mc }
    report.forges = { count = fc + gc, busy = fb + gb, magma = gc }
end)

-- 4. Manager orders: smelting and forging.
section('orders', function()
    local forge_jobs = {
        [df.job_type.MakeWeapon] = true, [df.job_type.MakeArmor] = true,
        [df.job_type.MakeHelm] = true, [df.job_type.MakeMetalCrafts or -1] = true,
    }
    local smelt_left, forge_left = 0, 0
    for _, o in ipairs(world.manager_orders.all or world.manager_orders) do
        if o.job_type == df.job_type.SmeltOre then
            smelt_left = smelt_left + o.amount_left
        elseif forge_jobs[o.job_type] then
            forge_left = forge_left + o.amount_left
        end
    end
    report.orders = { smelt_left = smelt_left, forge_left = forge_left }
end)

finish()
