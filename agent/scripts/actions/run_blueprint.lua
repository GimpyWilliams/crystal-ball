-- scripts/actions/run_blueprint.lua
--
-- Reversible write: apply (or undo) one bundled blueprint through DFHack's
-- quickfort API -- dig designations such as carved track, buildings such as
-- track stops, and stockpiles. Everything it creates is a designation or a
-- planned building that dwarves then carry out, and quickfort's own `undo`
-- removes it again.
--
-- Input: first vararg is JSON
--   {"command":"run"|"undo", "dry_run":true|false,
--    "phases":[{"mode":"dig"|"build"|"place", "label":"...",
--               "cells":[[x,y,z,"text"], ...]}, ...]}
-- Two non-quickfort phase modes:
--   "route":     {"route":"G2 pilot", "stops":[{"pos":[x,y,z], "conditions":
--                 [{"mode":"Push","direction":"South","load":"full"|"empty"}],
--                 "take_from":["G2-Feed"]}]}
--                sets each stop's departure conditions and, when take_from is
--                given, its take-from stockpile links (replacing any there);
--                undo clears them.
--   "build_now": {"area":[[x1,y1,z1],[x2,y2,z2]]} runs DFHack's build-now over
--                the area, finishing construction jobs whose materials are
--                already attached; undo does nothing (remove the building with
--                the build phase's undo).
--   "assign_carts": {"route":"G2 pilot"} runs DFHack's assign-minecarts for
--                that route (a free cart, if it has none); undo takes the cart
--                off the route again.
-- The phases come from a bundled agent/blueprints/*.json file; Python refuses
-- any other source. Cell coordinates are absolute map coordinates.
-- dry_run=true asks quickfort to validate and count without changing anything.
-- Output: {"ok":bool,"created":[{mode,label,stats,tiles}],"errors":[...]}.
--
-- Run via: RunCommand("lua", [<actions/_prelude.lua + this file>, <json spec>]).

local utils = require('utils')

if not (world.map.block_index ~= nil) then
    fail('no fortress is loaded')
    done()
    return
end

local spec = decode_spec(...)
if not spec then done() return end

local VALID_MODES = { dig = true, build = true, place = true,
                      route = true, build_now = true, assign_carts = true }
local QF_MODES = { dig = true, build = true, place = true }
local command = spec.command or 'run'
if command ~= 'run' and command ~= 'undo' then
    fail('command must be "run" or "undo"')
    done() return
end
local dry_run = spec.dry_run and true or false

-- Validate every phase and cell before touching quickfort.
local phases = spec.phases or {}
if #phases == 0 then fail('blueprint has no phases') done() return end
for i, ph in ipairs(phases) do
    if not VALID_MODES[ph.mode] then
        fail(('phase %d: unknown mode %s'):format(i, tostring(ph.mode)))
    end
    if ph.mode == 'assign_carts' and type(ph.route) ~= 'string' then
        fail(('phase %d: assign_carts needs "route"'):format(i))
    end
    if ph.mode == 'route' and (type(ph.route) ~= 'string' or type(ph.stops) ~= 'table') then
        fail(('phase %d: route needs "route" and "stops"'):format(i))
    end
    if ph.mode == 'build_now' and (type(ph.area) ~= 'table' or #ph.area ~= 2) then
        fail(('phase %d: build_now needs "area" [[x1,y1,z1],[x2,y2,z2]]'):format(i))
    end
    for j, c in ipairs(ph.cells or {}) do
        local x, y, z, t = c[1], c[2], c[3], c[4]
        if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number'
                or type(t) ~= 'string' or t == '' then
            fail(('phase %d cell %d: needs [x,y,z,"text"]'):format(i, j))
        elseif not dfhack.maps.isValidTilePos(x, y, z) then
            fail(('phase %d cell %d: (%d,%d,%d) is off the map'):format(i, j, x, y, z))
        end
    end
end
if not result.ok then done() return end

-- Live state of each target tile, so the preview shows what is there now.
local function tile_state(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    local shape = tt and df.tiletype_shape[df.tiletype.attrs[tt].shape] or '?'
    local occ = dfhack.maps.getTileBlock(x, y, z).occupancy[x % 16][y % 16]
    local track = (occ.carve_track_north or occ.carve_track_south
        or occ.carve_track_east or occ.carve_track_west) and true or false
    local bld = dfhack.buildings.findAtTile(xyz2pos(x, y, z))
    return { x = x, y = y, z = z, shape = shape, track_designated = track,
             building = bld and df.building_type[bld:getType()] or nil }
end

local qf_ok, quickfort = pcall(reqscript, 'quickfort')
if not qf_ok then
    fail('quickfort is not available: ' .. tostring(quickfort))
    done() return
end

-- Undo runs the phases in reverse so buildings come off before the track.
local order = {}
for i = 1, #phases do order[#order + 1] = phases[i] end
if command == 'undo' then
    for i = 1, math.floor(#order / 2) do
        order[i], order[#order - i + 1] = order[#order - i + 1], order[i]
    end
end

local function find_route(name)
    for _, r in ipairs(df.global.plotinfo.hauling.routes) do
        if r.name:lower() == name:lower() then return r end
    end
end

local function find_stop(route, pos)
    for _, s in ipairs(route.stops) do
        if s.pos.x == pos[1] and s.pos.y == pos[2] and s.pos.z == pos[3] then return s end
    end
end

local function cond_desc(c)
    local load = (c.flags.at_most and '<= ' or '>= ') .. c.load_percent .. '%'
    return ('%s %s, load %s'):format(df.stop_depart_condition.T_mode[c.mode],
        df.stop_depart_condition.T_direction[c.direction], load)
end

-- Departure conditions on existing route stops.
local function do_route(ph)
    local route = find_route(ph.route)
    if not route then return nil, 'no hauling route named "' .. ph.route .. '"' end
    local plan, tiles = {}, {}
    for _, st in ipairs(ph.stops) do
        local stop = find_stop(route, st.pos or {})
        if not stop then
            return nil, ('route "%s" has no stop at (%s)'):format(ph.route,
                table.concat(st.pos or {}, ','))
        end
        local conds = {}
        for _, c in ipairs(st.conditions or {}) do
            local mode = df.stop_depart_condition.T_mode[c.mode]
            local dir = df.stop_depart_condition.T_direction[c.direction]
            if not mode or not dir or (c.load ~= 'full' and c.load ~= 'empty') then
                return nil, 'bad condition: mode Push/Ride/Guide, direction North/South/East/West, load full/empty'
            end
            conds[#conds + 1] = { mode = mode, direction = dir, load = c.load }
        end
        local piles
        if st.take_from then
            piles = {}
            for _, name in ipairs(st.take_from) do
                -- every pile with that name (one blueprint row can make several)
                local found = false
                for _, b in ipairs(df.global.world.buildings.other.STOCKPILE) do
                    if b.name:lower() == tostring(name):lower() then
                        piles[#piles + 1] = b
                        found = true
                    end
                end
                if not found then return nil, 'no stockpile named "' .. tostring(name) .. '"' end
            end
        end
        plan[#plan + 1] = { stop = stop, conds = conds, piles = piles }
    end
    for _, p in ipairs(plan) do
        local before = {}
        for _, c in ipairs(p.stop.conditions) do before[#before + 1] = cond_desc(c) end
        local links_before = {}
        for _, l in ipairs(p.stop.stockpiles) do
            local b = df.building.find(l.building_id)
            links_before[#links_before + 1] = 'take from ' .. (b and b.name or ('#' .. l.building_id))
        end
        if p.piles then
            for _, s in ipairs(links_before) do before[#before + 1] = s end
        end
        if not dry_run and p.piles then
            -- drop the old links on both sides, then link the named piles
            for i = #p.stop.stockpiles - 1, 0, -1 do
                local b = df.building.find(p.stop.stockpiles[i].building_id)
                if b and b.linked_stops then
                    for j = #b.linked_stops - 1, 0, -1 do
                        if b.linked_stops[j] == p.stop then b.linked_stops:erase(j) end
                    end
                end
                p.stop.stockpiles[i]:delete()
                p.stop.stockpiles:erase(i)
            end
            if command == 'run' then
                for _, b in ipairs(p.piles) do
                    p.stop.stockpiles:insert('#', { new = df.route_stockpile_link,
                        building_id = b.id, mode = { take = true } })
                    b.linked_stops:insert('#', p.stop)
                end
            end
        end
        if not dry_run then
            for i = #p.stop.conditions - 1, 0, -1 do
                p.stop.conditions[i]:delete()
                p.stop.conditions:erase(i)
            end
            if command == 'run' then
                for _, c in ipairs(p.conds) do
                    local nc = df.stop_depart_condition:new()
                    nc.mode = c.mode
                    nc.direction = c.direction
                    nc.load_percent = (c.load == 'full') and 100 or 0
                    nc.flags.at_most = (c.load == 'empty')
                    p.stop.conditions:insert('#', nc)
                end
            end
        end
        local after = {}
        if dry_run then
            -- show what the run would set, since nothing was written
            if command == 'run' then
                for _, c in ipairs(p.conds) do
                    after[#after + 1] = ('%s %s, load %s'):format(
                        df.stop_depart_condition.T_mode[c.mode],
                        df.stop_depart_condition.T_direction[c.direction],
                        c.load == 'full' and '>= 100%' or '<= 0%')
                end
            end
        else
            for _, c in ipairs(p.stop.conditions) do after[#after + 1] = cond_desc(c) end
        end
        if p.piles then
            if dry_run then
                if command == 'run' then
                    for _, b in ipairs(p.piles) do after[#after + 1] = 'take from ' .. b.name end
                end
            else
                for _, l in ipairs(p.stop.stockpiles) do
                    local b = df.building.find(l.building_id)
                    after[#after + 1] = 'take from ' .. (b and b.name or ('#' .. l.building_id))
                end
            end
        end
        tiles[#tiles + 1] = { x = p.stop.pos.x, y = p.stop.pos.y, z = p.stop.pos.z,
            shape = 'stop ' .. p.stop.id, before = before, after = after }
    end
    local verb = (command == 'undo') and 'cleared' or 'given conditions'
    return { { name = 'route_stops', label = 'Route stops ' .. verb, value = #plan } }, tiles
end

-- Construction jobs inside the area whose materials are all attached.
local function count_ready(a, b)
    local n = 0
    for _, job in utils.listpairs(df.global.world.jobs.list) do
        if job.job_type == df.job_type.ConstructBuilding and not job.flags.suspend then
            local ready = true
            for _, ji in ipairs(job.job_items.elements) do
                if ji.quantity > 0 then ready = false end
            end
            local bld = dfhack.job.getHolder(job)
            if ready and bld and bld.x1 >= a[1] and bld.x2 <= b[1] and bld.y1 >= a[2]
                    and bld.y2 <= b[2] and bld.z >= a[3] and bld.z <= b[3] then
                n = n + 1
            end
        end
    end
    return n
end

local function do_build_now(ph)
    if command == 'undo' then
        return { { name = 'build_now', label = 'Nothing to undo for build-now', value = 0 } }, {}
    end
    local a, b = ph.area[1], ph.area[2]
    local ready = count_ready(a, b)
    if dry_run then
        return { { name = 'build_now', label = 'Construction jobs ready to finish', value = ready } }, {}
    end
    if ready > 0 then
        dfhack.run_script('build-now', ('%d,%d,%d'):format(a[1], a[2], a[3]),
            ('%d,%d,%d'):format(b[1], b[2], b[3]), '-q')
    end
    return { { name = 'build_now', label = 'Construction jobs finished',
               value = ready - count_ready(a, b) } }, {}
end

-- Put a free minecart on a route (or take it off on undo).
local function cart_desc(vid)
    local v = utils.binsearch(df.global.world.vehicles.all, vid, 'id')
    local it = v and df.item.find(v.item_id)
    if not it then return 'vehicle ' .. vid end
    local m = dfhack.matinfo.decode(it)
    return ('cart #%d %s at (%d,%d,%d)'):format(it.id, m and m:toString() or '?',
        it.pos.x, it.pos.y, it.pos.z)
end

local function do_assign_carts(ph)
    local route = find_route(ph.route)
    if not route then return nil, 'no hauling route named "' .. ph.route .. '"' end
    if #route.stops == 0 then return nil, 'route "' .. ph.route .. '" has no stops' end
    local before = {}
    for _, vid in ipairs(route.vehicle_ids) do before[#before + 1] = cart_desc(vid) end
    local free = 0
    for _, v in ipairs(df.global.world.vehicles.active) do
        if v.route_id == -1 then free = free + 1 end
    end
    if not dry_run then
        if command == 'undo' then
            for _, vid in ipairs(route.vehicle_ids) do
                local v = utils.binsearch(df.global.world.vehicles.all, vid, 'id')
                if v then v.route_id = -1 end
            end
            route.vehicle_ids:resize(0)
            route.vehicle_stops:resize(0)
        elseif #route.vehicle_ids == 0 then
            if free == 0 then return nil, 'no free minecarts to assign' end
            dfhack.run_script('assign-minecarts', tostring(route.id), '-q')
        end
    end
    local after = {}
    if dry_run then
        if command == 'undo' then after = {}
        elseif #before > 0 then after = before
        elseif free > 0 then after = { 'one of ' .. free .. ' free carts' } end
    else
        for _, vid in ipairs(route.vehicle_ids) do after[#after + 1] = cart_desc(vid) end
    end
    local label = (command == 'undo') and 'Carts taken off the route' or 'Carts on the route'
    return { { name = 'assign_carts', label = label,
               value = (command == 'undo') and #before or #after } },
           { { x = route.stops[0].pos.x, y = route.stops[0].pos.y, z = route.stops[0].pos.z,
               shape = 'route ' .. route.id, before = before, after = after } }
end

local NON_QF = { route = do_route, build_now = do_build_now, assign_carts = do_assign_carts }

for _, ph in ipairs(order) do
    if not QF_MODES[ph.mode] then
        local fn = NON_QF[ph.mode]
        local ok, stats, tiles = pcall(fn, ph)
        if not ok then
            fail(('%s phase "%s": %s'):format(ph.mode, tostring(ph.label), tostring(stats)))
        elseif not stats then
            fail(('%s phase "%s": %s'):format(ph.mode, tostring(ph.label), tostring(tiles)))
        else
            result.created[#result.created + 1] = {
                mode = ph.mode, label = ph.label, stats = stats, tiles = tiles,
            }
        end
        goto next_phase
    end
    local data, tiles = {}, {}
    for _, c in ipairs(ph.cells) do
        local x, y, z, t = c[1], c[2], c[3], c[4]
        data[z] = data[z] or {}
        data[z][y] = data[z][y] or {}
        data[z][y][x] = t
        tiles[#tiles + 1] = tile_state(x, y, z)
    end
    local ok, stats = pcall(quickfort.apply_blueprint, {
        mode = ph.mode, data = data, command = command, dry_run = dry_run,
    })
    if not ok then
        fail(('%s phase "%s": %s'):format(ph.mode, tostring(ph.label), tostring(stats)))
    else
        local s = {}
        for name, st in pairs(stats or {}) do
            if type(st) == 'table' and st.value and st.value ~= 0 then
                s[#s + 1] = { name = name, label = st.label, value = st.value }
            end
        end
        result.created[#result.created + 1] = {
            mode = ph.mode, label = ph.label, stats = s, tiles = tiles,
        }
    end
    ::next_phase::
end

done()
