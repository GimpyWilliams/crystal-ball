-- stockpile_config.lua
--
-- READ-ONLY. For every stockpile, report its CONFIGURATION rather than its
-- contents: which item categories it is set to accept, how many give/take links
-- it has, and (where the build exposes them) its bin/barrel/wheelbarrow caps.
-- This is the "why won't my output store here / why is this pile pulling from
-- there" lens that contents-only tools (stockpile_locate, container_audit) miss.
-- Mutates NOTHING.
--
-- The stockpile settings layout is one of the more version-fragile structs in
-- DF, so EVERY field is read in its own pcall: a layout change on a future build
-- drops that one field (e.g. the container caps, which are absent on some
-- builds) and degrades to an omission, never a broken report.
--
-- Shared helpers (section, world, report, finish, fort_loaded) come from
-- scripts/_prelude.lua, prepended by intel.py.
--
-- Run via: RunCommand("lua", [<prelude + this file>]).

if not report.fort_loaded then finish() return end

-- Top-level accept categories on building_stockpilest.settings.flags.
local CATS = { 'animals', 'food', 'furniture', 'corpses', 'refuse', 'stone',
    'ore', 'ammo', 'coins', 'bars_blocks', 'gems', 'finished_goods', 'leather',
    'cloth', 'wood', 'weapons', 'armor', 'sheet' }

local piles = {}

for _, b in ipairs(world.buildings.all) do
    if df.building_stockpilest:is_instance(b) then
        local rec = {}
        pcall(function() rec.number = b.stockpile_number end)
        pcall(function()
            local n = tostring(b.name)
            if n ~= '' then rec.name = n end
        end)
        pcall(function() rec.pos = { x = b.x1, y = b.y1, z = b.z } end)

        -- Which categories this pile accepts (top-level enable flags).
        local enabled = {}
        -- Guard each category separately: a flag missing in this DF build
        -- (e.g. 'ore') must not abort the loop and hide every later category.
        for _, cat in ipairs(CATS) do
            pcall(function()
                if b.settings.flags[cat] then enabled[#enabled + 1] = cat end
            end)
        end
        rec.accepts = enabled

        -- Links to/from other piles.
        pcall(function() rec.links_give = #b.links.give_to_pile end)
        pcall(function() rec.links_take = #b.links.take_from_pile end)

        -- Container caps: b.storage on DF 50+, directly on b on older builds.
        for _, k in ipairs({ 'max_bins', 'max_barrels', 'max_wheelbarrows' }) do
            if not pcall(function() rec[k] = b.storage[k] end) then
                pcall(function() rec[k] = b[k] end)
            end
        end

        -- Furniture types it does NOT take (Furniture enabled only), so a pile
        -- that ticks Furniture but excludes containers is visible.
        pcall(function()
            if not b.settings.flags.furniture then return end
            local t, on, off = b.settings.furniture.type, {}, {}
            for i = 0, df.furniture_type._last_item do
                -- vector<char> on DF 50+: 0 is unticked (and truthy in Lua).
                local v = i < #t and t[i]
                if v == true or (type(v) == 'number' and v ~= 0) then on[#on + 1] = df.furniture_type[i]
                else off[#off + 1] = df.furniture_type[i] end
            end
            rec.furniture_types = on
            rec.furniture_off = off
        end)

        piles[#piles + 1] = rec
    end
end

report.stockpiles = piles
finish()
