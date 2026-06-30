-- shops_and_orders.lua
--
-- READ-ONLY view of production capacity and the manager order queue.
-- Workshops/furnaces grouped by type with idle/busy/suspended job counts, plus
-- every manager work order with its remaining amount and status. Together these
-- answer "do I have a free workshop?" and "is my order actually active?".
-- Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

local json = require('json')
local world = df.global.world

local report = { errors = {} }
report.fort_loaded = (world.map.block_index ~= nil)
if not report.fort_loaded then
    print(json.encode(report))
    return
end

local function section(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        report.errors[#report.errors + 1] = name .. ': ' .. tostring(err)
    end
end

-- Human-readable material name from a (mat_type, mat_index) pair, mirroring the
-- helper in brewing_intel.lua / stock_query.lua. Returns nil for "no concrete
-- material" (mat_type < 0) so callers can fall back to the material_category.
local function matname(mat_type, mat_index)
    if not mat_type or mat_type < 0 then return nil end
    local mi = dfhack.matinfo.decode(mat_type, mat_index)
    return mi and mi:toString()
        or ('mat:' .. tostring(mat_type) .. ':' .. tostring(mat_index))
end

-- Building (workshop/furnace) type name, same logic as the workshops section.
local function building_name(b)
    if df.building_workshopst:is_instance(b) then
        return df.workshop_type[b.type] or ('Workshop:' .. tostring(b.type))
    elseif df.building_furnacest:is_instance(b) then
        return 'Furnace:' .. tostring(df.furnace_type[b.type] or b.type)
    end
    return nil
end

-- Generic material class from a job_material_category bitfield (e.g. "stone",
-- "wood", "cloth"). Returns the set flag names joined, or nil if none set.
local function category_name(cat)
    if not cat then return nil end
    local names = {}
    for k, v in pairs(cat) do
        if v == true then names[#names + 1] = k end
    end
    if #names == 0 then return nil end
    table.sort(names)
    return table.concat(names, '+')
end

-- Material descriptor for an order/condition: concrete material if set,
-- else the generic material-category class, else nil. The material_category
-- field exists on orders but not on condition items, so read it defensively.
local function order_material(rec)
    local m = matname(rec.mat_type, rec.mat_index)
    if m then return m end
    local cat
    pcall(function() cat = rec.material_category end)
    return category_name(cat)
end

local _FREQUENCY = {
    [0] = 'one-time', [1] = 'daily', [2] = 'monthly',
    [3] = 'seasonal', [4] = 'yearly',
}

-- Map an order condition's comparison (df.logic_condition_type) to a symbol.
local _COMPARE = {
    AtLeast = '>=', AtMost = '<=', GreaterThan = '>',
    LessThan = '<', Exactly = '==', Not = '~=',
}
local function compare_symbol(c)
    local n = c.compare_type
    local name = df.logic_condition_type and df.logic_condition_type[n]
    return _COMPARE[name] or tostring(name or n)
end

section('workshops', function()
    local shops = {}
    for _, b in ipairs(world.buildings.all) do
        local tname = building_name(b)
        if tname then
            local s = shops[tname]
            if not s then
                s = { count = 0, idle = 0, busy = 0, suspended_jobs = 0 }
                shops[tname] = s
            end
            s.count = s.count + 1
            if #b.jobs > 0 then s.busy = s.busy + 1 else s.idle = s.idle + 1 end
            for _, j in ipairs(b.jobs) do
                if j.flags.suspend then
                    s.suspended_jobs = s.suspended_jobs + 1
                end
            end
        end
    end
    report.workshops = shops
end)

section('orders', function()
    local orders = {}
    local list = world.manager_orders.all or world.manager_orders
    for _, o in ipairs(list) do
        local rec = {
            job_type = df.job_type[o.job_type] or tostring(o.job_type),
            reaction_name = (o.reaction_name ~= '' and o.reaction_name) or nil,
            amount_total = o.amount_total,
            amount_left = o.amount_left,
        }
        pcall(function() rec.active = o.status.active end)
        pcall(function() rec.validated = o.status.validated end)

        -- What material the order produces: concrete material if pinned,
        -- otherwise the generic class (stone/wood/cloth/...).
        pcall(function() rec.material = order_material(o) end)

        -- One-time vs repeating (daily/monthly/seasonal/yearly).
        pcall(function()
            rec.frequency = _FREQUENCY[o.frequency] or tostring(o.frequency)
        end)

        -- Pinned to a specific workshop? (-1 / nil means "any").
        pcall(function()
            local wid = o.workshop_id
            if wid and wid >= 0 then
                local b = df.building.find(wid)
                local n = b and building_name(b)
                if n then rec.workshop = n .. ' #' .. tostring(wid) end
            end
        end)

        -- Stock/order conditions gating this order. Isolated in its own pcall:
        -- this is the most version-fragile decode, so on any failure we drop the
        -- conditions for this order and note it, rather than losing the order.
        local cok, cerr = pcall(function()
            local conds = {}
            for _, c in ipairs(o.item_conditions) do
                local parts = {}
                local m = order_material(c)
                if m then parts[#parts + 1] = m end
                local it = df.item_type[c.item_type]
                if it and it ~= 'NONE' then parts[#parts + 1] = it end
                local subj = #parts > 0 and table.concat(parts, ' ') or 'item'
                conds[#conds + 1] = subj .. ' ' .. compare_symbol(c)
                    .. ' ' .. tostring(c.compare_val)
            end
            for _, c in ipairs(o.order_conditions) do
                conds[#conds + 1] = 'after order #' .. tostring(c.order_id)
                    .. ' done'
            end
            if #conds > 0 then rec.conditions = conds end
        end)
        if not cok then
            report.errors[#report.errors + 1] =
                'order conditions: ' .. tostring(cerr)
        end

        orders[#orders + 1] = rec
    end
    report.orders = orders
end)

print(json.encode(report))
