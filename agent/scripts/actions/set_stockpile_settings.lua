-- scripts/actions/set_stockpile_settings.lua
--
-- Reversible write: set a stockpile's FURNITURE and FINISHED-GOODS accept-types,
-- a minimum quality on those two categories, and its container caps (max bins /
-- barrels / wheelbarrows). Never touches any other category, the pile's name,
-- extents, links or contents.
--
-- Input: first vararg is JSON
--   {"piles":[{"number":55,"expect_name":"",
--              "furniture_types":["DOOR"],        -- exact set; enables Furniture
--              "furniture_except":["BARREL"],     -- or: every type but these
--              "untick_types":["BIN"],            -- or: turn these off
--              "disable_furniture":true,          -- or: turn Furniture off
--              "finished_goods_types":["TOOL"],   -- exact df.item_type set;
--                                                 --   enables Finished goods
--              "finished_goods_untick":["INSTRUMENT"], -- or: turn just these off
--              "disable_finished_goods":true,     -- or: turn Finished goods off
--              "finished_goods_materials":["GOLD"],  -- inorganic ids, or the
--                  tokens "@METAL" / "@NONMETAL"; ticks only these materials
--              "finished_goods_materials_except":["SILVER"], -- then un-ticks these
--              "finished_goods_other_materials":false, -- wood/bone/glass etc.
--              "coin_materials":["SILVER"],       -- enables Coins, only these
--              "stone_materials":["@ORE","@ECONOMIC"], -- Stone category: ticks
--                  only these (inorganic ids, or the class tokens @ORE = any
--                  metal-ore stone, @ECONOMIC = other economic stone such as
--                  flux and fuel, @PLAIN = everything else); needs Stone enabled
--              "stone_untick":["@PLAIN"],         -- or: turn just these off
--              "min_quality":"FinelyCrafted",     -- lowest ticked quality
--              "max_bins":0,"max_barrels":0,"max_wheelbarrows":0}]}
-- stone_materials and stone_untick are mutually exclusive.
-- At most one of the four furniture modes per pile; every other field is
-- optional. min_quality applies to each of Furniture / Finished goods that the
-- entry sets types for, or, if it sets none, to whichever is already enabled.
-- `expect_name` is the name the planner read moments ago ("" for an unnamed
-- pile); a pile whose name differs is refused, so a stale preview cannot be
-- applied to a pile that was changed since.
--
-- Enabling a category on a pile that never had it: DF leaves its filter vectors
-- empty (accepts nothing), so they are sized from a pile that already has the
-- category and every material, colour and quality is turned on, as the in-game
-- "enable" does.
--
-- All-or-nothing validation: every entry is checked BEFORE any write. Each
-- write is then pcall-wrapped and read back. The old state is returned so the
-- change can be undone.
-- Output: {"ok":bool,"created":[{number,name,before,after}],"errors":[...]}.
--
-- Run via: RunCommand("lua", [<actions/_prelude.lua + this file>, <json spec>]).

if not (world.map.block_index ~= nil) then
    fail('no fortress is loaded')
    done()
    return
end

local spec = decode_spec(...)
if not spec then done() return end
if type(spec.piles) ~= 'table' or #spec.piles == 0 then
    fail('spec.piles must be a non-empty list')
    done() return
end

local CAPS = { 'max_bins', 'max_barrels', 'max_wheelbarrows' }
local CAP_MAX = 10000
local FT = df.furniture_type
local N_FURN = FT._last_item + 1
local N_QUAL = df.item_quality._last_item + 1

-- The filter vectors are vector<char> on DF 50+ (0/1 integers, where Lua
-- treats 0 as TRUE) and bool on some builds; read and write through these.
local function is_on(v) return v == true or (type(v) == 'number' and v ~= 0) end
local function put(vec, i, on)
    if not pcall(function() vec[i] = on and 1 or 0 end) then vec[i] = on end
end

local piles = {}
for _, b in ipairs(world.buildings.all) do
    if df.building_stockpilest:is_instance(b) then
        piles[b.stockpile_number] = b
    end
end

local function current_name(b)
    local n = ''
    pcall(function() n = tostring(b.name) end)
    return n
end

-- A pile whose category is enabled and configured, to size new vectors from.
local function template_for(cat)
    for _, b in pairs(piles) do
        local ok, t = pcall(function()
            if b.settings.flags[cat] and #b.settings[cat].mats > 0 then
                return b.settings[cat]
            end
        end)
        if ok and t then return t end
    end
end

local function ticked(vec, names)
    local out = {}
    for i = 0, #vec - 1 do
        if is_on(vec[i]) then out[#out + 1] = names(i) end
    end
    return out
end

local function snapshot(b)
    local s = { furniture = b.settings.flags.furniture,
                finished_goods = b.settings.flags.finished_goods }
    s.types = ticked(b.settings.furniture.type, function(i) return FT[i] end)
    s.fg_types = ticked(b.settings.finished_goods.type,
        function(i) return df.item_type[i] end)
    s.fg_mat_count = #ticked(b.settings.finished_goods.mats, function(i) return i end)
    s.fg_other_mat_count = #ticked(b.settings.finished_goods.other_mats, function(i) return i end)
    s.stone = b.settings.flags.stone
    s.stone_mat_count = #ticked(b.settings.stone.mats, function(i) return i end)
    s.coins = b.settings.flags.coins
    s.coin_mat_count = #ticked(b.settings.coins.mats, function(i) return i end)
    s.furniture_qualities = ticked(b.settings.furniture.quality_core,
        function(i) return df.item_quality[i] end)
    s.fg_qualities = ticked(b.settings.finished_goods.quality_core,
        function(i) return df.item_quality[i] end)
    for _, k in ipairs(CAPS) do s[k] = b.storage[k] end
    return s
end

-- Inorganic material ids -> index; "@METAL" / "@NONMETAL" select by IS_METAL.
local INORG = world.raws.inorganics.all
local INORG_IDX, IS_METAL = {}, {}
for i = 0, #INORG - 1 do
    INORG_IDX[INORG[i].id] = i
    local ok, v = pcall(function() return INORG[i].material.flags.IS_METAL end)
    IS_METAL[i] = ok and v == true
end

-- Stone classes for the Stone category: ORE = any metal-ore stone, ECONOMIC =
-- other economic stone (flux, fuel...), PLAIN = remaining IS_STONE materials.
local STONE_CLASS = {}
for i = 0, #INORG - 1 do
    local m = INORG[i]
    local okS, isStone = pcall(function() return m.material.flags.IS_STONE end)
    if okS and isStone then
        local c = 'PLAIN'
        pcall(function()
            if #m.metal_ore.mat_index > 0 then c = 'ORE'
            elseif #m.economic_uses > 0 then c = 'ECONOMIC' end
        end)
        STONE_CLASS[i] = c
    end
end

local function resolve_stone(list, label, what)
    if type(list) ~= 'table' or #list == 0 then
        fail(label .. ': ' .. what .. ' must be a non-empty list'); return nil
    end
    local set = {}
    for _, n in ipairs(list) do
        n = tostring(n)
        local cls = n:match('^@(%u+)$')
        if cls == 'ORE' or cls == 'ECONOMIC' or cls == 'PLAIN' then
            for i, c in pairs(STONE_CLASS) do if c == cls then set[i] = true end end
        elseif INORG_IDX[n] and STONE_CLASS[INORG_IDX[n]] then
            set[INORG_IDX[n]] = true
        else
            fail(label .. ': unknown stone ' .. n); return nil
        end
    end
    return set
end

local function resolve_mats(list, label, what)
    if type(list) ~= 'table' or #list == 0 then
        fail(label .. ': ' .. what .. ' must be a non-empty list'); return nil
    end
    local set = {}
    for _, n in ipairs(list) do
        n = tostring(n)
        if n == '@METAL' or n == '@NONMETAL' then
            for i = 0, #INORG - 1 do
                if IS_METAL[i] == (n == '@METAL') then set[i] = true end
            end
        elseif INORG_IDX[n] then
            set[INORG_IDX[n]] = true
        else
            fail(label .. ': unknown material ' .. n); return nil
        end
    end
    return set
end

local function resolve(list, enum, limit, label, what)
    if type(list) ~= 'table' or #list == 0 then
        fail(label .. ': ' .. what .. ' must be a non-empty list')
        return nil
    end
    local set = {}
    for _, n in ipairs(list) do
        local i = enum[tostring(n)]
        if type(i) ~= 'number' or i < 0 or i >= limit then
            fail(label .. ': unknown ' .. what .. ' ' .. tostring(n))
            return nil
        end
        set[i] = true
    end
    return set
end

-- Validate everything first.
local plan, seen = {}, {}
for idx, p in ipairs(spec.piles) do
    local num = tonumber(p.number)
    local label = 'entry ' .. idx .. ' (#' .. tostring(p.number) .. ')'
    local b = num and piles[num]
    local modes = (p.furniture_types and 1 or 0) + (p.untick_types and 1 or 0)
        + (p.furniture_except and 1 or 0) + (p.disable_furniture and 1 or 0)
    local fg_modes = (p.finished_goods_types and 1 or 0)
        + (p.finished_goods_untick and 1 or 0) + (p.disable_finished_goods and 1 or 0)
    local ok = true
    if not num or num ~= math.floor(num) then
        fail(label .. ': number must be an integer'); ok = false
    elseif not b then
        fail(label .. ': no stockpile with that number'); ok = false
    elseif seen[num] then
        fail(label .. ': pile listed twice'); ok = false
    elseif current_name(b) ~= tostring(p.expect_name or '') then
        fail(label .. ": current name is '" .. current_name(b) ..
            "', expected '" .. tostring(p.expect_name or '') .. "'"); ok = false
    elseif modes > 1 then
        fail(label .. ': give only one of furniture_types, furniture_except, '
            .. 'untick_types, disable_furniture'); ok = false
    elseif p.untick_types and not b.settings.flags.furniture then
        fail(label .. ': untick_types needs Furniture already enabled'); ok = false
    elseif fg_modes > 1 then
        fail(label .. ': give only one of finished_goods_types, '
            .. 'finished_goods_untick, disable_finished_goods'); ok = false
    elseif p.finished_goods_untick and not b.settings.flags.finished_goods then
        fail(label .. ': finished_goods_untick needs Finished goods already enabled')
        ok = false
    elseif p.disable_finished_goods and (p.finished_goods_materials
            or p.finished_goods_materials_except
            or p.finished_goods_other_materials ~= nil) then
        fail(label .. ': disable_finished_goods cannot be combined with '
            .. 'finished-goods material filters'); ok = false
    end
    local entry = { b = b, num = num, caps = {} }
    if ok and p.furniture_types then
        entry.set = resolve(p.furniture_types, FT, N_FURN, label, 'furniture type')
        ok = entry.set ~= nil
    elseif ok and p.furniture_except then
        local ex = resolve(p.furniture_except, FT, N_FURN, label, 'furniture type')
        ok = ex ~= nil
        if ok then
            entry.set = {}
            for i = 0, N_FURN - 1 do if not ex[i] then entry.set[i] = true end end
        end
    elseif ok and p.untick_types then
        entry.unset = resolve(p.untick_types, FT, N_FURN, label, 'furniture type')
        ok = entry.unset ~= nil
    elseif ok and p.disable_furniture then
        entry.disable = true
    end
    if ok and p.finished_goods_types then
        local limit = 0
        local t = template_for('finished_goods')
        if t then limit = #t.type end
        if limit == 0 then
            fail(label .. ': no configured Finished goods pile to size from')
            ok = false
        else
            entry.fg = resolve(p.finished_goods_types, df.item_type, limit,
                label, 'item type')
            ok = entry.fg ~= nil
        end
    end
    if ok and p.finished_goods_untick then
        entry.fg_unset = resolve(p.finished_goods_untick, df.item_type,
            #b.settings.finished_goods.type, label, 'item type')
        ok = entry.fg_unset ~= nil
    elseif ok and p.disable_finished_goods then
        entry.fg_disable = true
    end
    if ok and p.finished_goods_materials then
        entry.fg_mats = resolve_mats(p.finished_goods_materials, label,
            'finished_goods_materials')
        ok = entry.fg_mats ~= nil
        if ok and p.finished_goods_materials_except then
            local ex = resolve_mats(p.finished_goods_materials_except, label,
                'finished_goods_materials_except')
            ok = ex ~= nil
            if ok then for i in pairs(ex) do entry.fg_mats[i] = nil end end
        end
        if ok and not entry.fg and not b.settings.flags.finished_goods then
            fail(label .. ': finished_goods_materials needs Finished goods enabled')
            ok = false
        end
    elseif ok and p.finished_goods_materials_except then
        fail(label .. ': finished_goods_materials_except needs finished_goods_materials')
        ok = false
    end
    if ok and p.finished_goods_other_materials ~= nil then
        if type(p.finished_goods_other_materials) ~= 'boolean' then
            fail(label .. ': finished_goods_other_materials must be true or false')
            ok = false
        else
            entry.fg_other = p.finished_goods_other_materials
        end
    end
    if ok and p.coin_materials then
        entry.coin_mats = resolve_mats(p.coin_materials, label, 'coin_materials')
        ok = entry.coin_mats ~= nil
        if ok and not template_for('coins') and not b.settings.flags.coins then
            fail(label .. ': no configured Coins pile to size from'); ok = false
        end
    end
    if ok and (p.stone_materials or p.stone_untick) then
        if p.stone_materials and p.stone_untick then
            fail(label .. ': give only one of stone_materials, stone_untick')
            ok = false
        elseif not b.settings.flags.stone then
            fail(label .. ': stone filters need the Stone category enabled')
            ok = false
        elseif p.stone_materials then
            entry.stone_set = resolve_stone(p.stone_materials, label, 'stone_materials')
            ok = entry.stone_set ~= nil
        else
            entry.stone_unset = resolve_stone(p.stone_untick, label, 'stone_untick')
            ok = entry.stone_unset ~= nil
        end
    end
    if ok and p.min_quality ~= nil then
        local q = df.item_quality[tostring(p.min_quality)]
        if type(q) ~= 'number' or q < 0 or q >= N_QUAL then
            fail(label .. ': unknown quality ' .. tostring(p.min_quality))
            ok = false
        else
            entry.minq = q
        end
    end
    if ok and entry.set and not b.settings.flags.furniture and not template_for('furniture') then
        fail(label .. ': no configured Furniture pile to size from'); ok = false
    end
    if ok then
        for _, k in ipairs(CAPS) do
            local v = p[k]
            if v ~= nil then
                v = tonumber(v)
                if not v or v ~= math.floor(v) or v < 0 or v > CAP_MAX then
                    fail(label .. ': ' .. k .. ' must be an integer 0-' .. CAP_MAX)
                    ok = false
                else
                    entry.caps[k] = v
                end
            end
        end
    end
    if ok and not (entry.set or entry.unset or entry.disable or entry.fg
            or entry.fg_unset or entry.fg_disable or entry.minq or entry.fg_mats or entry.fg_other ~= nil
            or entry.coin_mats or entry.stone_set or entry.stone_unset
            or next(entry.caps)) then
        fail(label .. ': nothing to change'); ok = false
    end
    if ok then
        seen[num] = true
        plan[#plan + 1] = entry
    end
end

if not result.ok or #result.errors > 0 then
    result.ok = false
    done() return
end

local function fill(vec, n, val)
    if #vec ~= n then vec:resize(n) end
    for i = 0, n - 1 do put(vec, i, val) end
end

-- Switch a category on, sizing every filter vector from a configured pile and
-- turning everything on except `type` (the caller sets that).
local function enable_category(b, cat)
    local tmpl = template_for(cat)
    local s = b.settings[cat]
    for k, v in pairs(tmpl) do
        if type(v) == 'boolean' then
            s[k] = true
        elseif k == 'type' then
            fill(s[k], #v, false)
        else
            fill(s[k], #v, true)
        end
    end
    b.settings.flags[cat] = true
end

local function set_quality(s, minq)
    for _, k in ipairs({ 'quality_core', 'quality_total' }) do
        for i = 0, #s[k] - 1 do put(s[k], i, i >= minq) end
    end
end

local function set_types(b, cat, set)
    local s = b.settings[cat]
    if not b.settings.flags[cat] or #s.type == 0 then enable_category(b, cat) end
    for i = 0, #s.type - 1 do put(s.type, i, set[i] == true) end
end

-- Write, then read back.
for _, e in ipairs(plan) do
    local before = snapshot(e.b)
    local touched = {}
    local ok, err = pcall(function()
        if e.set then
            set_types(e.b, 'furniture', e.set); touched.furniture = true
        elseif e.unset then
            for i in pairs(e.unset) do put(e.b.settings.furniture.type, i, false) end
        elseif e.disable then
            e.b.settings.flags.furniture = false
        end
        if e.fg then
            set_types(e.b, 'finished_goods', e.fg); touched.finished_goods = true
        elseif e.fg_unset then
            for i in pairs(e.fg_unset) do
                put(e.b.settings.finished_goods.type, i, false)
            end
        elseif e.fg_disable then
            e.b.settings.flags.finished_goods = false
        end
        if e.fg_mats or e.fg_other ~= nil then
            local s = e.b.settings.finished_goods
            if e.fg_mats then
                for i = 0, #s.mats - 1 do put(s.mats, i, e.fg_mats[i] == true) end
            end
            if e.fg_other ~= nil then
                for i = 0, #s.other_mats - 1 do put(s.other_mats, i, e.fg_other) end
            end
        end
        if e.coin_mats then
            local s = e.b.settings.coins
            if not e.b.settings.flags.coins or #s.mats == 0 then
                enable_category(e.b, 'coins')
            end
            for i = 0, #s.mats - 1 do put(s.mats, i, e.coin_mats[i] == true) end
        end
        if e.stone_set then
            local v = e.b.settings.stone.mats
            for i = 0, #v - 1 do put(v, i, e.stone_set[i] == true) end
        elseif e.stone_unset then
            local v = e.b.settings.stone.mats
            for i in pairs(e.stone_unset) do if i < #v then put(v, i, false) end end
        end
        if e.minq then
            local any = touched.furniture or touched.finished_goods
            for _, cat in ipairs({ 'furniture', 'finished_goods' }) do
                if touched[cat] or (not any and e.b.settings.flags[cat]) then
                    set_quality(e.b.settings[cat], e.minq)
                end
            end
        end
        for k, v in pairs(e.caps) do e.b.storage[k] = v end
    end)
    if not ok then
        fail('#' .. e.num .. ': write failed: ' .. tostring(err))
    else
        local after = snapshot(e.b)
        local good = true
        local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
        if e.set then good = good and after.furniture and #after.types == count(e.set)
        elseif e.unset then
            for i in pairs(e.unset) do
                if is_on(e.b.settings.furniture.type[i]) then good = false end
            end
        elseif e.disable then good = good and not after.furniture end
        if e.fg then good = good and after.finished_goods and #after.fg_types == count(e.fg)
        elseif e.fg_unset then
            for i in pairs(e.fg_unset) do
                if is_on(e.b.settings.finished_goods.type[i]) then good = false end
            end
        elseif e.fg_disable then good = good and not after.finished_goods end
        if e.fg_mats then
            local n = 0 for _ in pairs(e.fg_mats) do n = n + 1 end
            if after.fg_mat_count ~= n then good = false end
        end
        if e.fg_other ~= nil and (after.fg_other_mat_count == 0) ~= (not e.fg_other) then
            good = false
        end
        if e.coin_mats then
            local n = 0 for _ in pairs(e.coin_mats) do n = n + 1 end
            if not after.coins or after.coin_mat_count ~= n then good = false end
        end
        if e.stone_set then
            local n = 0 for _ in pairs(e.stone_set) do n = n + 1 end
            if after.stone_mat_count ~= n then good = false end
        elseif e.stone_unset then
            for i in pairs(e.stone_unset) do
                if is_on(e.b.settings.stone.mats[i]) then good = false end
            end
        end
        if e.minq then
            for _, q in ipairs(after.furniture_qualities) do
                if touched.furniture and df.item_quality[q] < e.minq then good = false end
            end
            for _, q in ipairs(after.fg_qualities) do
                if touched.finished_goods and df.item_quality[q] < e.minq then good = false end
            end
        end
        for k, v in pairs(e.caps) do if after[k] ~= v then good = false end end
        if not good then
            fail('#' .. e.num .. ': write did not stick')
        else
            result.created[#result.created + 1] = {
                number = e.num, name = current_name(e.b), before = before, after = after }
        end
    end
end

done()
