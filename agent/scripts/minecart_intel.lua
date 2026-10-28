-- minecart_intel.lua
--
-- READ-ONLY status of the fort's minecart logistics, for the minecart project:
--   carts[]       : every on-map minecart item (id, material, pos, vehicle/route)
--   routes[]      : hauling routes (plotinfo.hauling.routes) with their stops,
--                   each stop's position, linked stockpiles and item conditions
--   trackstops[]  : track-stop buildings (pos, friction, dump direction)
--   rollers       : count of roller buildings
--   orders[]      : manager orders whose product is a minecart
--   quantum[]     : 1x1 stockpiles (the usual quantum-dump target)
--   dig           : designated-but-undug tiles on the optional z level given as
--                   the first vararg (the strip-mine level), by designation type
-- Shared helpers (section, report, finish, world...) from scripts/_prelude.lua.
--
-- Run via: RunCommand("lua", [<prelude + this file>, <z>]).

if not report.fort_loaded then finish() return end

local dig_z = tonumber((...))

local function minecart_subtype()
    for i, d in ipairs(world.raws.itemdefs.tools) do
        if d.id == 'ITEM_TOOL_MINECART' then return i end
    end
    return nil
end
local CART = minecart_subtype()
report.minecart_subtype = CART

section('carts', function()
    local by_item = {}
    pcall(function()
        for _, v in ipairs(world.vehicles.all) do by_item[v.item_id] = v end
    end)
    local out = {}
    for _, it in ipairs(world.items.all) do
        if it:getType() == df.item_type.TOOL and it:getSubtype() == CART then
            local x, y, z = dfhack.items.getPosition(it)
            if x and x >= 0 then
                local v = by_item[it.id]
                out[#out + 1] = {
                    id = it.id, mat = matname(it.mat_type, it.mat_index),
                    x = x, y = y, z = z,
                    vehicle = v and v.id or nil,
                    route = v and v.route_id or nil,
                    forbidden = it.flags.forbid or nil,
                }
            end
        end
    end
    report.carts = out
end)

section('routes', function()
    local out = {}
    for _, r in ipairs(df.global.plotinfo.hauling.routes) do
        local stops = {}
        for _, s in ipairs(r.stops) do
            local piles = {}
            pcall(function()
                for _, l in ipairs(s.stockpiles) do
                    local b = df.building.find(l.building_id)
                    piles[#piles + 1] = b and b.stockpile_number or l.building_id
                end
            end)
            local nconds = 0
            pcall(function() nconds = #s.conditions end)
            stops[#stops + 1] = {
                id = s.id, name = tostring(s.name),
                x = s.pos.x, y = s.pos.y, z = s.pos.z,
                piles = piles, conditions = nconds,
            }
        end
        local nveh = 0
        pcall(function() nveh = #r.vehicle_ids end)
        out[#out + 1] = { id = r.id, name = tostring(r.name), stops = stops,
                          vehicles = nveh }
    end
    report.routes = out
end)

section('track', function()
    local stops, rollers = {}, 0
    for _, b in ipairs(world.buildings.all) do
        local t = b:getType()
        if t == df.building_type.Trap and b.trap_type == df.trap_type.TrackStop then
            local s = { x = b.x1, y = b.y1, z = b.z, name = tostring(b.name) }
            pcall(function() s.friction = b.friction end)
            pcall(function()
                if b.use_dump ~= 0 and b.use_dump ~= false then
                    s.dump = { dx = b.dump_x_shift, dy = b.dump_y_shift }
                end
            end)
            stops[#stops + 1] = s
        elseif t == df.building_type.Rollers then
            rollers = rollers + 1
        end
    end
    report.trackstops = stops
    report.rollers = rollers
end)

section('orders', function()
    local out = {}
    for _, o in ipairs(world.manager_orders.all) do
        if o.item_type == df.item_type.TOOL and o.item_subtype == CART then
            out[#out + 1] = { id = o.id, left = o.amount_left,
                              total = o.amount_total,
                              job = df.job_type[o.job_type] }
        end
    end
    report.orders = out
end)

section('quantum', function()
    local out = {}
    for _, b in ipairs(world.buildings.all) do
        if df.building_stockpilest:is_instance(b) and b.x1 == b.x2 and b.y1 == b.y2 then
            out[#out + 1] = { number = b.stockpile_number, name = tostring(b.name),
                              x = b.x1, y = b.y1, z = b.z }
        end
    end
    report.quantum = out
end)

if dig_z then
    section('dig', function()
        local counts, total = {}, 0
        local m = world.map
        for bx = 0, m.x_count_block - 1 do
            for by = 0, m.y_count_block - 1 do
                local blk = dfhack.maps.getBlock(bx, by, dig_z)
                if blk then
                    for lx = 0, 15 do
                        for ly = 0, 15 do
                            local d = blk.designation[lx][ly].dig
                            if d ~= df.tile_dig_designation.No then
                                local k = df.tile_dig_designation[d]
                                counts[k] = (counts[k] or 0) + 1
                                total = total + 1
                            end
                        end
                    end
                end
            end
        end
        report.dig = { z = dig_z, total = total, by_type = counts }
    end)
end

finish()
