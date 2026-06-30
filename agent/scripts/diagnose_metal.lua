-- diagnose_metal.lua
--
-- READ-ONLY root-cause analysis for "why isn't metal being made?". Walks the
-- smelting pipeline (ore -> smelter -> bars), with fuel as a gate (unless a
-- magma smelter makes fuel moot) and forging as secondary context. Mutates
-- NOTHING. Shared helpers come from scripts/_prelude.lua.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end
report.target = 'metal bars'
report.facts = {}

-- 1. Is there a smelter (regular or magma)?
local smelters, magma_smelters = 0, 0
pcall(function() smelters = ({ furnaces_of(df.furnace_type.Smelter) })[1] end)
pcall(function() magma_smelters = ({ furnaces_of(df.furnace_type.MagmaSmelter) })[1] end)
local total_smelters = smelters + magma_smelters
report.facts.smelters = total_smelters
report.facts.magma_smelters = magma_smelters
add('smelter_exists', total_smelters > 0, 'blocker',
    total_smelters .. ' smelter(s) built (' .. magma_smelters .. ' magma)')

-- 2. Is there metal ore on hand?
local ore_free = 0
pcall(function()
    for _, it in ipairs(world.items.other.BOULDER) do
        local mi = dfhack.matinfo.decode(it)
        local is_ore = false
        if mi and mi.inorganic then
            pcall(function() is_ore = mi.inorganic.flags.METAL_ORE end)
        end
        if is_ore and is_available(it) then ore_free = ore_free + it.stack_size end
    end
end)
report.facts.ore_free = ore_free
add('ore_available', ore_free > 0, 'blocker',
    ore_free .. ' unforbidden metal-ore boulder(s) on hand')

-- 3. Fuel: a regular smelter needs charcoal/coke; a magma smelter does not. Only
-- a blocker when there is NO magma smelter and no fuel on hand.
local fuel_units = 0
pcall(function()
    for _, it in ipairs(world.items.other.BAR) do
        local n = (matdesc(it) or ''):lower()
        if n:find('charcoal') or n:find('coke') or n == 'coal' then
            if is_available(it) then fuel_units = fuel_units + it.stack_size end
        end
    end
end)
report.facts.fuel_units = fuel_units
if magma_smelters > 0 then
    add('fuel_for_smelting', true, 'blocker',
        'magma smelter present; no charcoal/coke needed (' .. fuel_units ..
        ' fuel on hand)')
else
    add('fuel_for_smelting', fuel_units > 0, 'blocker',
        fuel_units .. ' charcoal/coke on hand (a non-magma smelter needs fuel)')
end

-- 4. Is anyone assigned to operate the furnace (SMELT labor)?
local smelt_ok, smelt_detail = labor_check('SMELT')
add('smelter_labor', smelt_ok, 'blocker', 'smelt (SMELT): ' .. smelt_detail)

-- 5. Forging context (secondary): forge built + a metalsmith assigned.
local forges = 0
pcall(function()
    forges = ({ workshops_of(df.workshop_type.MetalsmithsForge) })[1]
        + ({ workshops_of(df.workshop_type.MagmaForge) })[1]
end)
report.facts.forges = forges
add('forge_exists', forges > 0, 'info', forges .. ' forge(s) built')
local weap_ok, weap_detail = labor_check('FORGE_WEAPON')
add('forge_labor', weap_ok, 'info', 'forge weapons (FORGE_WEAPON): ' .. weap_detail)

finish()
