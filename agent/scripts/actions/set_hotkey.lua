-- scripts/actions/set_hotkey.lua
--
-- Reversible write: set or clear one F-key map bookmark
-- (df.global.plotinfo.main.hotkeys[key_id-1]).
--
-- Input: first vararg is JSON {"key_id":6,"name":"Thread pile","x":27,"y":35,"z":122}.
-- To CLEAR a slot, pass name="" (sets cmd=-1, coords to 0).
-- To SET a slot, pass a non-empty name and integer x/y/z (sets cmd=0).
-- Validation: key_id 1-16; coords must be integers; checked BEFORE any write.
-- Output: {"ok":bool,"created":[{key,old,new}],"errors":[...]}.
-- `new.active` mirrors cmd==0 so the Python renderer can show a clear diff.
--
-- Run via: RunCommand("lua", [<actions/_prelude.lua + this file>, <json spec>]).

if not (world.map.block_index ~= nil) then
    fail('no fortress is loaded')
    done()
    return
end

local spec = decode_spec(...)
if not spec then done() return end

-- Validate key_id.
local kid = tonumber(spec.key_id)
if not kid or kid < 1 or kid > 16 or kid ~= math.floor(kid) then
    fail('key_id must be an integer 1-16 (F1=1 … F16=16)')
    done() return
end
kid = math.floor(kid)

local h = df.global.plotinfo.main.hotkeys[kid - 1]
if not h then
    fail('hotkey slot F' .. tostring(kid) .. ' not accessible on this DF build')
    done() return
end

-- Capture current state before any write.
local old = {
    key    = 'F' .. tostring(kid),
    name   = tostring(h.name),
    x      = h.x,
    y      = h.y,
    z      = h.z,
    active = (h.cmd == 0),
}

local new_name = tostring(spec.name or '')
local clearing = (new_name == '')

if clearing then
    -- Clear the slot: blank name, cmd=-1, coords zeroed.
    local ok, err = pcall(function()
        h.name = ''
        h.cmd  = -1
        h.x    = 0
        h.y    = 0
        h.z    = 0
    end)
    if not ok then
        fail('could not clear F' .. tostring(kid) .. ': ' .. tostring(err))
        done() return
    end
    result.created[#result.created + 1] = {
        key = 'F' .. tostring(kid),
        old = old,
        new = { key = 'F' .. tostring(kid), name = '', x = 0, y = 0, z = 0, active = false },
    }
else
    -- Set the slot: validate coordinates first, then write.
    local function intcoord(val, label)
        local n = tonumber(val)
        if not n or n ~= math.floor(n) then
            fail(label .. ': must be an integer (got ' .. tostring(val) .. ')')
            return nil
        end
        return math.floor(n)
    end
    local nx = intcoord(spec.x, 'x')
    local ny = intcoord(spec.y, 'y')
    local nz = intcoord(spec.z, 'z')
    if not nx or not ny or not nz then done() return end

    local ok, err = pcall(function()
        h.name = new_name
        h.x    = nx
        h.y    = ny
        h.z    = nz
        h.cmd  = 0
    end)
    if not ok then
        fail('could not set F' .. tostring(kid) .. ': ' .. tostring(err))
        done() return
    end
    result.created[#result.created + 1] = {
        key = 'F' .. tostring(kid),
        old = old,
        new = { key = 'F' .. tostring(kid), name = new_name,
                x = nx, y = ny, z = nz, active = true },
    }
end

done()
