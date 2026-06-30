-- dump_raws.lua
--
-- READ-ONLY snapshot of the loaded world's STATIC schema -- the enums and raw
-- subtype tables that are fixed for a given world + mod-load. This is consumed
-- by resolve.py (Python), cached to data/raws_<world_id>.json, and used to map a
-- free-text filter ("nest box", "iron breastplate") to a concrete
-- (item_type, subtype) BEFORE any live query. It is the foundation that lets the
-- locate/stock tools accept human names and return precise, token-safe results.
-- Mutates NOTHING.
--
-- The output is read by Python and written to disk -- it is NEVER returned to the
-- model -- so the size of the full dump (1300+ tool defs, 500+ instruments) is
-- fine and the token cap that bites stock_data does not apply here.
--
-- Modes:
--   (no arg)  -> full dump: identity + enums + itemdef subtype tables
--   "id"      -> identity only (world_id/world_name/save_dir): a cheap freshness
--                check so resolve.py can tell if its cache matches the live world
--
-- Shared helpers (section, finish, world, report, report.fort_loaded) come from
-- scripts/_prelude.lua, which intel.py prepends to this file.
--
-- Run via: RunCommand("lua", [<prelude + this file>])  or  [..., "id"]

if not report.fort_loaded then finish() return end

-- Identity: world_header.id1 is a stable numeric world id; save_dir is the save
-- folder ("region1"); world_name is the readable world name. Each in its own
-- pcall so a layout change on a future DF build degrades one field, not the dump.
section('identity', function()
    local sg = world.cur_savegame
    pcall(function() report.world_id  = sg.world_header.id1 end)
    pcall(function() report.world_name = sg.world_header.world_name end)
    pcall(function() report.save_dir   = sg.save_dir end)
end)

-- "id" mode stops here: the caller only wanted the freshness key.
if (select(1, ...) or '') == 'id' then finish() return end

-- Enum dump: name -> index, via NUMERIC enumeration. pairs(df.<enum>) only yields
-- a handful of keys on this build (the enum is special userdata), so we must walk
-- _first_item.._last_item and read each index back to its name.
local function dump_enum(E)
    local out = {}
    local lo, hi = E._first_item, E._last_item
    if lo and hi then
        for i = lo, hi do
            local nm = E[i]
            if nm then out[nm] = i end
        end
    end
    return out
end

report.enums = {}
local function add_enum(name, E)
    section('enum:' .. name, function() report.enums[name] = dump_enum(E) end)
end
add_enum('item_type',     df.item_type)
add_enum('building_type', df.building_type)
add_enum('workshop_type', df.workshop_type)
add_enum('furnace_type',  df.furnace_type)
add_enum('trap_type',     df.trap_type)
add_enum('civzone_type',  df.civzone_type)

-- Itemdef subtype tables. We snapshot only the REAL subtype lists and skip the
-- ~80 *_graphics_info tables, tools_by_type, and `all` that also live under
-- itemdefs. Each entry: {i=index, id=raw token, name, name_plural}. The Python
-- resolver maps each table name to its item_type enum (tools->TOOL, armor->ARMOR).
local DEF_TABLES = { 'tools', 'weapons', 'armor', 'shoes', 'helms', 'gloves',
    'pants', 'shields', 'ammo', 'siege_ammo', 'trapcomps', 'toys',
    'instruments', 'food' }

report.itemdefs = {}
for _, key in ipairs(DEF_TABLES) do
    section('itemdef:' .. key, function()
        local vec = world.raws.itemdefs[key]
        local list = {}
        if vec then
            for i = 0, #vec - 1 do
                local d = vec[i]
                -- Read each label defensively: some def structs lack a field
                -- (e.g. itemdef_foodst has no name_plural), and a missing field
                -- must drop that one label, not the whole entry/table.
                local e = { i = i }
                pcall(function() e.id = tostring(d.id) end)
                pcall(function() e.name = tostring(d.name) end)
                pcall(function() e.name_plural = tostring(d.name_plural) end)
                list[#list + 1] = e
            end
        end
        report.itemdefs[key] = list
    end)
end

finish()
