-- stock_probe.lua
--
-- READ-ONLY cheap freshness probe for the stock baseline cache (stockcache.py).
-- Returns the world identity, the in-game clock, and the per-type loose-item
-- vector lengths -- everything get_broad() needs to decide, WITHOUT a full
-- classify scan. #world.items.other[TYPE] is O(1), so probing all ~94 item
-- types is milliseconds. Mutates NOTHING.
--
-- Output:
--   { fort_loaded, world_id, cur_year, cur_year_tick, vector_lens = {TYPE=len,...} }
-- vector_lens omits zero-length types (a type absent here but present in the
-- baseline has emptied; a nonzero type absent from the baseline is new stock).
--
-- Shared helpers (world, report, report.fort_loaded, finish) come from
-- scripts/_prelude.lua, prepended by intel.py.
--
-- Run via: RunCommand("lua", [<prelude + this file>])

if not report.fort_loaded then finish() return end

-- world_id: world_header.id1 is the stable numeric id stockcache keys its file
-- on -- the same key dump_raws.lua / resolve.py use. Each read pcall-guarded so
-- a future layout change degrades one field instead of the whole probe.
pcall(function() report.world_id = world.cur_savegame.world_header.id1 end)
pcall(function() report.cur_year = df.global.cur_year end)
pcall(function() report.cur_year_tick = df.global.cur_year_tick end)

-- Per-type loose-item vector lengths. Enums enumerate by numeric index (pairs()
-- yields only a few keys on this build), so walk _first_item.._last_item.
local lens = {}
local it = df.item_type
for i = it._first_item, it._last_item do
    local nm = it[i]
    if nm then
        pcall(function()
            local vec = world.items.other[nm]
            if vec and #vec > 0 then lens[nm] = #vec end
        end)
    end
end
report.vector_lens = lens

finish()
