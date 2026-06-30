-- scripts/actions/create_order.lua
--
-- The single, audited mutation that backs queue_work_order, auto_stock_target,
-- fix_idle and manage_containers: create one or more manager orders.
--
-- Input: the first vararg is a JSON object  {"orders": [<spec>, ...]}  where each
-- <spec> is as documented in _prelude.lua's validate_order(). It is DATA only.
--
-- Discipline (see _prelude.lua): EVERY order is validated first; only orders that
-- pass are written; each write is pcall-wrapped. Invalid specs become errors,
-- never crashes. Output: {"ok":bool,"created":[...],"errors":[...]}.
--
-- Run via: RunCommand("lua", [<prelude+this file>, <json spec>]).

if not (world.map.block_index ~= nil) then
    fail('no fortress is loaded')
    done()
    return
end

local spec = decode_spec(...)
if not spec then done() return end

local orders = spec.orders or {}
if #orders == 0 then
    fail('spec contained no orders')
    done()
    return
end

-- Validate the whole batch first; collect resolved specs and per-item errors.
local resolved = {}
for i, o in ipairs(orders) do
    local v, err = validate_order(o)
    if v then
        resolved[#resolved + 1] = v
    else
        fail('order #' .. i .. ': ' .. err)
    end
end

-- Apply only the orders that passed validation. A write failure on one order is
-- recorded and does not abort the rest.
for _, v in ipairs(resolved) do
    local ok, err = pcall(apply_order, v)
    if not ok then
        fail('apply ' .. tostring(v.label) .. ': ' .. tostring(err))
    end
end

done()
