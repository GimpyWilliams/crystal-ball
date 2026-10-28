-- scripts/actions/set_burrow_units.lua
--
-- Reversible write: add units to, or remove units from, ONE existing burrow's
-- assigned-unit list (dfhack.burrows.setAssignedUnit). Never creates or deletes a
-- burrow, never edits its tiles or name, and never touches a unit not listed.
--
-- Input: first vararg is JSON
--   {"burrow_id":0,"expect_name":"","action":"add","unit_ids":[22134,21695]}
-- `expect_name` is the burrow's name as the planner read it moments ago; a burrow
-- renamed since is refused, so a stale preview cannot act on the wrong burrow.
-- `action` is "add" or "remove".
--
-- All-or-nothing validation: the burrow and every unit are checked BEFORE any
-- write; if any entry is bad, nothing is written. A unit already in the requested
-- state is skipped (reported, not an error). Each write is pcall-wrapped and read
-- back to confirm it stuck.
-- Output: {"ok":bool,"created":[{unit,name,old,new}],"skipped":[...],"errors":[...]}.
-- `old`/`new` are "assigned" / "not assigned" so the Python renderer can show the
-- diff and the exact undo.
--
-- Run via: RunCommand("lua", [<actions/_prelude.lua + this file>, <json spec>]).

if not (world.map.block_index ~= nil) then
    fail('no fortress is loaded')
    done()
    return
end

local spec = decode_spec(...)
if not spec then done() return end

local MAX_UNITS = 200

local action = spec.action
if action ~= 'add' and action ~= 'remove' then
    fail("action must be 'add' or 'remove' (got " .. tostring(action) .. ')')
    done() return
end
if type(spec.unit_ids) ~= 'table' or #spec.unit_ids == 0 then
    fail('spec.unit_ids must be a non-empty list')
    done() return
end
if #spec.unit_ids > MAX_UNITS then
    fail('at most ' .. MAX_UNITS .. ' units per call (got ' .. #spec.unit_ids .. ')')
    done() return
end

-- Find the burrow by id and confirm it is still the one the planner saw.
local burrow
local bid = tonumber(spec.burrow_id)
for _, b in ipairs(df.global.plotinfo.burrows.list) do
    if b.id == bid then burrow = b break end
end
if not burrow then
    fail('no burrow with id ' .. tostring(spec.burrow_id))
    done() return
end
if tostring(burrow.name) ~= tostring(spec.expect_name or '') then
    fail("burrow #" .. bid .. " is now named '" .. tostring(burrow.name) ..
        "', expected '" .. tostring(spec.expect_name or '') .. "'")
    done() return
end

-- Validate every unit first.
local adding = (action == 'add')
local plan, seen = {}, {}
for i, raw in ipairs(spec.unit_ids) do
    local id = tonumber(raw)
    local label = 'entry ' .. i .. ' (unit ' .. tostring(raw) .. ')'
    local u = id and df.unit.find(id)
    if not id or id ~= math.floor(id) then
        fail(label .. ': unit id must be an integer')
    elseif seen[id] then
        fail(label .. ': duplicate unit id')
    elseif not u then
        fail(label .. ': no such unit')
    elseif not dfhack.units.isCitizen(u) or not dfhack.units.isAlive(u) then
        fail(label .. ': not a living fortress citizen')
    else
        seen[id] = true
        local name = dfhack.units.getReadableName(u)
        local has = dfhack.burrows.isAssignedUnit(burrow, u)
        if has == adding then
            result.skipped = result.skipped or {}
            result.skipped[#result.skipped + 1] = {
                unit = id, name = name,
                why = adding and 'already assigned' or 'not assigned',
            }
        else
            plan[#plan + 1] = { u = u, id = id, name = name, had = has }
        end
    end
end

if #result.errors > 0 then
    result.ok = false
    done() return
end

-- Write, then read back.
local function label_of(assigned) return assigned and 'assigned' or 'not assigned' end
for _, p in ipairs(plan) do
    local ok, err = pcall(dfhack.burrows.setAssignedUnit, burrow, p.u, adding)
    if not ok then
        fail('unit ' .. p.id .. ': could not set assignment: ' .. tostring(err))
    elseif dfhack.burrows.isAssignedUnit(burrow, p.u) ~= adding then
        fail('unit ' .. p.id .. ': write did not stick')
    else
        result.created[#result.created + 1] = {
            unit = p.id, name = p.name,
            old = label_of(p.had), new = label_of(adding),
        }
    end
end

done()
