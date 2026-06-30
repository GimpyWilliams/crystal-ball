-- diagnose_fuel.lua
--
-- READ-ONLY root-cause analysis for "why isn't fuel (charcoal) being made?".
-- Walks the charcoal pipeline (logs -> wood furnace -> charcoal) and notes when
-- magma makes fuel optional. Mutates NOTHING. Shared helpers come from
-- scripts/_prelude.lua.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end
report.target = 'charcoal'
report.facts = {}

-- 1. Is there a wood furnace to make charcoal at?
local wood_furnaces = ({ furnaces_of(df.furnace_type.WoodFurnace) })[1]
report.facts.wood_furnaces = wood_furnaces
add('woodfurnace_exists', wood_furnaces > 0, 'blocker',
    wood_furnaces .. ' wood furnace(s) built')

-- 2. Are there logs to burn?
local logs = 0
pcall(function()
    for _, it in ipairs(world.items.other.WOOD) do
        if is_available(it) then logs = logs + it.stack_size end
    end
end)
report.facts.logs_free = logs
add('wood_available', logs > 0, 'blocker', logs .. ' log(s) on hand to burn')

-- 3. Is anyone assigned to burn wood (BURN_WOOD labor)?
local burn_ok, burn_detail = labor_check('BURN_WOOD')
add('burner_assigned', burn_ok, 'blocker', 'burn wood (BURN_WOOD): ' .. burn_detail)

-- 4. Magma context: magma smelters/forges need no charcoal, so fuel may be
-- optional for the metal industry. Info only.
local magma = 0
pcall(function()
    magma = ({ furnaces_of(df.furnace_type.MagmaSmelter) })[1]
        + ({ workshops_of(df.workshop_type.MagmaForge) })[1]
end)
report.facts.magma_buildings = magma
add('magma_alternative', magma == 0, 'info',
    magma .. ' magma smelter/forge(s) (these need no charcoal)')

finish()
