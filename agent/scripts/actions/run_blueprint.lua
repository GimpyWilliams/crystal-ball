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
-- The phases come from a bundled agent/blueprints/*.json file; Python refuses
-- any other source. Cell coordinates are absolute map coordinates.
-- dry_run=true asks quickfort to validate and count without changing anything.
-- Output: {"ok":bool,"created":[{mode,label,stats,tiles}],"errors":[...]}.
--
-- Run via: RunCommand("lua", [<actions/_prelude.lua + this file>, <json spec>]).

if not (world.map.block_index ~= nil) then
    fail('no fortress is loaded')
    done()
    return
end

local spec = decode_spec(...)
if not spec then done() return end

local VALID_MODES = { dig = true, build = true, place = true }
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

for _, ph in ipairs(order) do
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
end

done()
