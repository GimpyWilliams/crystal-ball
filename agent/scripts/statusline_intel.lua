-- statusline_intel.lua
--
-- READ-ONLY minimal snapshot for the Claude Code status line: in-game clock
-- and site name only. Deliberately tiny (~O(1) fields) -- it runs inside the
-- same shared_connection as the roster/mood/key-stock queries the statusline
-- snapshot (statusline.py) batches alongside it, so this adds negligible time
-- to what is otherwise just those existing near-instant queries.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end

section('timestamp', function()
    report.cur_year      = df.global.cur_year
    report.cur_year_tick = df.global.cur_year_tick
end)

section('site', function()
    local site = dfhack.world.getCurrentSite()
    if site then
        report.site_name = location_name(site)
    end
end)

finish()
