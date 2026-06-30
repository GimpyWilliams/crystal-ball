-- diagnose_construction.lua
--
-- READ-ONLY root-cause analysis for the building-materials industries. Each of
-- masonry, carpentry, glass and mechanisms is a simple workshop + input +
-- labor chain; this reports a blocker per sub-industry so you can see which one
-- is stalled and why. Mutates NOTHING. Shared helpers come from
-- scripts/_prelude.lua.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end
report.target = 'building materials'
report.facts = {}

local function free_units(tname)
    local total = 0
    local vec = world.items.other[tname]
    if vec then
        for _, it in ipairs(vec) do
            if is_available(it) then total = total + it.stack_size end
        end
    end
    return total
end

local stone = free_units('BOULDER')
local logs = free_units('WOOD')
report.facts.stone_free = stone
report.facts.logs_free = logs

-- Masonry: Mason's shop + stone + MASON.
local masons = ({ workshops_of(df.workshop_type.Masons) })[1]
report.facts.mason_shops = masons
add('masonry_shop', masons > 0, 'blocker', masons .. " mason's shop(s) built")
add('masonry_stone', stone > 0, 'blocker', stone .. ' boulder(s) on hand to cut')
local mason_ok, mason_detail = labor_check('MASON')
add('masonry_labor', mason_ok, 'blocker', 'masonry (MASON): ' .. mason_detail)

-- Carpentry: Carpenter's shop + logs + CARPENTER.
local carps = ({ workshops_of(df.workshop_type.Carpenters) })[1]
report.facts.carpenter_shops = carps
add('carpentry_shop', carps > 0, 'blocker', carps .. " carpenter's shop(s) built")
add('carpentry_logs', logs > 0, 'blocker', logs .. ' log(s) on hand to build with')
local carp_ok, carp_detail = labor_check('CARPENTER')
add('carpentry_labor', carp_ok, 'blocker', 'carpentry (CARPENTER): ' .. carp_detail)

-- Mechanisms: Mechanic's shop + stone + MECHANIC.
local mechs = ({ workshops_of(df.workshop_type.Mechanics) })[1]
report.facts.mechanic_shops = mechs
add('mechanisms_shop', mechs > 0, 'blocker', mechs .. " mechanic's shop(s) built")
add('mechanisms_stone', stone > 0, 'blocker', stone .. ' boulder(s) on hand')
local mech_ok, mech_detail = labor_check('MECHANIC')
add('mechanisms_labor', mech_ok, 'blocker', 'mechanisms (MECHANIC): ' .. mech_detail)

-- Glass: glass furnace + GLASSMAKER (sand+fuel are info -- sand isn't cleanly
-- enumerable, and magma glass furnaces need no fuel).
local gf = ({ furnaces_of(df.furnace_type.GlassFurnace) })[1]
local mgf = ({ furnaces_of(df.furnace_type.MagmaGlassFurnace) })[1]
report.facts.glass_furnaces = gf + mgf
add('glass_furnace', (gf + mgf) > 0, 'blocker',
    (gf + mgf) .. ' glass furnace(s) built (' .. mgf .. ' magma)')
local glass_ok, glass_detail = labor_check('GLASSMAKER')
add('glass_labor', glass_ok, 'blocker', 'glassmaking (GLASSMAKER): ' .. glass_detail)
add('glass_sand', nil, 'info',
    'glass needs a bag of sand (gather via CollectSand near sand) and, for a '
    .. 'non-magma furnace, fuel; sand on hand is not cleanly detectable here')

finish()
