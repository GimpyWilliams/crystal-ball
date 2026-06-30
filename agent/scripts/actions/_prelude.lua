-- scripts/actions/_prelude.lua
--
-- Canonical helpers shared by every WRITE ("act") script. actions.py's
-- run_action() prepends this file to each mutation script before sending it over
-- the DFHack RPC, so the functions below are available as GLOBALS to every
-- action script. This is the single source of truth for the one load-bearing
-- mutation -- creating a manager order -- and its safety discipline:
--
--   1. Every enum/material lookup is validated BEFORE anything is written, so a
--      bad job/reaction/material name returns an error instead of corrupting a
--      df struct (which could crash DF).
--   2. The actual insert is wrapped in pcall and recorded, so a partial failure
--      is reported rather than silently half-applied.
--
-- Manager orders are the safest thing to mutate: ordinary game data, created and
-- cancelled constantly in normal play, and trivially reversible in-game.

json = require('json')
world = df.global.world

-- Result accumulator. Action scripts push into created/errors and call done().
result = { ok = true, created = {}, errors = {} }

function fail(msg)
    result.ok = false
    result.errors[#result.errors + 1] = tostring(msg)
end

function done()
    if #result.created == 0 then result.ok = false end
    print(json.encode(result))
end

-- Decode the JSON spec passed as the first vararg. Returns a Lua table or nil.
function decode_spec(...)
    local raw = ...
    if not raw or raw == '' then return nil end
    local ok, spec = pcall(json.decode, raw)
    if not ok then
        fail('could not decode order spec JSON: ' .. tostring(spec))
        return nil
    end
    return spec
end

-- The manager-order list and the next-id counter differ slightly across DF
-- builds; resolve both defensively.
local function order_list()
    return world.manager_orders.all or world.manager_orders
end

local function next_order_id()
    -- Prefer the engine's counter; fall back to max(existing)+1.
    local ok, id = pcall(function() return world.manager_order_next_id end)
    if ok and id then
        world.manager_order_next_id = id + 1
        return id
    end
    local maxid = -1
    for _, o in ipairs(order_list()) do
        if o.id and o.id > maxid then maxid = o.id end
    end
    return maxid + 1
end

local _FREQUENCY = {
    ['one-time'] = 0, daily = 1, monthly = 2, seasonal = 3, yearly = 4,
}

-- Built-in "make X from a material" jobs: the game UI forces a material choice
-- for these, so we must too. Creating one with no material yields the bogus
-- "make unknown material crafts" order. A CustomReaction is exempt (its material
-- comes from the reaction's reagents), as are jobs that operate on existing
-- items without a material pin (CutGems, PrepareRawFish, BrewDrink-style, ...).
local MATERIAL_REQUIRED = {
    MakeCrafts = true, ConstructBlocks = true, ConstructMechanisms = true,
    ConstructStatue = true, WeaveCloth = true,
}

-- Validate one order spec WITHOUT writing. Returns (resolved, err) where
-- `resolved` is a table of vetted fields ready to apply, or err is a string.
--
-- spec fields (all data, never code):
--   job            df.job_type name, e.g. "MakeRockCrafts" / "CustomReaction"
--   reaction_name  custom-reaction code, e.g. "BREW_DRINK_FROM_PLANT" (optional)
--   amount         integer > 0
--   material_category  optional flag name on the order's material_category
--                      bitfield, e.g. "stone" / "wood" / "cloth"
--   frequency      one of one-time/daily/monthly/seasonal/yearly (default one-time)
--   condition      optional {item_type=, mat_category=, below=N} -> "when < N"
function validate_order(spec)
    if type(spec) ~= 'table' then return nil, 'order spec is not an object' end

    local amount = tonumber(spec.amount)
    if not amount or amount < 1 then
        return nil, 'amount must be a positive integer (got ' ..
            tostring(spec.amount) .. ')'
    end

    local jt = spec.job
    if not jt or df.job_type[jt] == nil then
        return nil, 'unknown job_type ' .. tostring(jt)
    end

    -- Reaction validation: a CustomReaction needs a code that exists; a plain
    -- job must not carry one.
    local rname = spec.reaction_name
    if rname and rname ~= '' then
        local found = false
        for _, r in ipairs(world.raws.reactions.reactions) do
            if r.code == rname then found = true break end
        end
        if not found then
            return nil, 'unknown reaction ' .. tostring(rname)
        end
    elseif jt == 'CustomReaction' then
        return nil, 'CustomReaction order requires a reaction_name'
    end

    local freq = _FREQUENCY[spec.frequency or 'one-time']
    if freq == nil then
        return nil, 'unknown frequency ' .. tostring(spec.frequency)
    end

    -- Resolve the material. DF encodes a craft's material in the mat_type/
    -- mat_index pair (e.g. (0,-1) == generic "rock"); the material_category
    -- bitfield is organic-only (plant/wood/cloth/silk/...). Accept three forms,
    -- in priority order: an explicit (mat_type, mat_index); a material NAME the
    -- game resolves (e.g. "MICROCLINE", "GRANITE"); or an organic category flag.
    local mat_type, mat_index = -1, -1
    if spec.material_name then
        local mi = dfhack.matinfo.find(spec.material_name)
        if not mi then
            return nil, 'unknown material ' .. tostring(spec.material_name)
        end
        mat_type, mat_index = mi.type, mi.index
    elseif spec.mat_type ~= nil then
        mat_type = tonumber(spec.mat_type) or -1
        mat_index = tonumber(spec.mat_index) or -1
    end

    local matcat = spec.material_category
    if matcat ~= nil then
        local probe = df.manager_order:new()
        local okflag = pcall(function() return probe.material_category[matcat] end)
        probe:delete()
        if not okflag then
            return nil, 'unknown material_category ' .. tostring(matcat)
        end
    end

    -- Guard: never emit a "make unknown material X" order. A material-required
    -- job must end up with a concrete mat_type OR an organic category flag.
    if MATERIAL_REQUIRED[jt] and mat_type < 0 and matcat == nil then
        return nil, jt .. " needs a material -- pass material='stone' (generic " ..
            "rock), an organic class like 'wood'/'silk', or a specific material " ..
            "name. Refusing to create an unknown-material order."
    end

    -- A condition needs an item_type that resolves.
    local cond = spec.condition
    if cond ~= nil then
        if cond.item_type and df.item_type[cond.item_type] == nil then
            return nil, 'condition: unknown item_type ' .. tostring(cond.item_type)
        end
        if not tonumber(cond.below) then
            return nil, 'condition: "below" must be a number'
        end
    end

    return {
        job = jt, reaction_name = spec.reaction_name, amount = math.floor(amount),
        mat_type = mat_type, mat_index = mat_index,
        material_category = matcat, frequency = freq, condition = cond,
        label = spec.label or jt,
    }, nil
end

-- Apply ONE pre-validated order. Wrapped in pcall by the caller via create_order.
function apply_order(v)
    local order = df.manager_order:new()
    order.id = next_order_id()
    order.job_type = df.job_type[v.job]
    order.item_type = -1
    order.item_subtype = -1
    order.mat_type = v.mat_type or -1
    order.mat_index = v.mat_index or -1
    if v.reaction_name and v.reaction_name ~= '' then
        order.reaction_name = v.reaction_name
    end
    if v.material_category then
        order.material_category[v.material_category] = true
    end
    order.amount_total = v.amount
    order.amount_left = v.amount
    order.frequency = v.frequency
    -- A fresh order must be validated+active to actually run.
    pcall(function() order.status.validated = true end)
    pcall(function() order.status.active = true end)

    if v.condition then
        -- vector:insert() returns nothing; grab the freshly-added element by
        -- index (DFHack vectors are 0-based, so last = count-1).
        order.item_conditions:insert('#', {new = true})
        local c = order.item_conditions[#order.item_conditions - 1]
        if not c then error('could not create order condition') end
        c.compare_type = df.logic_condition_type.LessThan
        c.compare_val = math.floor(tonumber(v.condition.below))
        if v.condition.item_type then
            c.item_type = df.item_type[v.condition.item_type]
        end
        if v.condition.mat_category then
            pcall(function()
                c.material_category[v.condition.mat_category] = true
            end)
        end
    end

    order_list():insert('#', order)
    result.created[#result.created + 1] = {
        id = order.id, job = v.job, amount = v.amount, label = v.label,
    }
end
