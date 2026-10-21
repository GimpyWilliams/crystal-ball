-- scripts/actions/rename_stockpiles.lua
--
-- Reversible write: set the display NAME of one or more stockpiles. Changes the
-- label only -- never what a pile accepts, its size, links or contents.
--
-- Input: first vararg is JSON
--   {"renames":[{"number":16,"expect_old":"Stone Furniture","new":"FURN-Stone"}]}
-- `number` is the stockpile_number shown in game; `expect_old` is the name the
-- planner read moments ago ("" for an unnamed pile). A pile whose current name
-- differs is refused, so a stale preview cannot overwrite a rename made since.
--
-- All-or-nothing validation: every entry is checked BEFORE any write; if any
-- entry is bad, nothing is written. Each write is then pcall-wrapped and read
-- back to confirm it stuck.
-- Output: {"ok":bool,"created":[{number,old,new}],"errors":[...]}.
--
-- Run via: RunCommand("lua", [<actions/_prelude.lua + this file>, <json spec>]).

if not (world.map.block_index ~= nil) then
    fail('no fortress is loaded')
    done()
    return
end

local spec = decode_spec(...)
if not spec then done() return end
if type(spec.renames) ~= 'table' or #spec.renames == 0 then
    fail('spec.renames must be a non-empty list')
    done() return
end

local MAX_LEN = 40

-- Index every stockpile by number.
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

-- Validate everything first.
local plan, seen_new, renaming = {}, {}, {}
for _, r in ipairs(spec.renames) do
    renaming[tonumber(r.number) or -1] = true
end
for i, r in ipairs(spec.renames) do
    local num = tonumber(r.number)
    local new = r.new
    local label = 'entry ' .. i .. ' (#' .. tostring(r.number) .. ')'
    if not num or num ~= math.floor(num) then
        fail(label .. ': number must be an integer')
    elseif not piles[num] then
        fail(label .. ': no stockpile with that number')
    elseif type(new) ~= 'string' or new == '' or #new > MAX_LEN then
        fail(label .. ': new name must be 1-' .. MAX_LEN .. ' characters')
    elseif new:find('[^%w%-_ /]') then
        fail(label .. ': new name may only use letters, digits, space, - _ /')
    elseif seen_new[new] then
        fail(label .. ': duplicate new name ' .. new)
    elseif current_name(piles[num]) ~= tostring(r.expect_old or '') then
        fail(label .. ": current name is '" .. current_name(piles[num]) ..
            "', expected '" .. tostring(r.expect_old or '') .. "'")
    else
        seen_new[new] = true
        plan[#plan + 1] = { b = piles[num], num = num, old = current_name(piles[num]), new = new }
    end
end

-- A new name must not collide with a pile that is staying as it is.
for _, p in ipairs(plan) do
    for n, b in pairs(piles) do
        if n ~= p.num and not renaming[n] and current_name(b) == p.new then
            fail('#' .. p.num .. ': name ' .. p.new .. ' is already used by #' .. n)
        end
    end
end

if not result.ok or #result.errors > 0 then
    result.ok = false
    done() return
end

-- Write, then read back.
for _, p in ipairs(plan) do
    local ok, err = pcall(function() p.b.name = p.new end)
    if not ok then
        fail('#' .. p.num .. ': could not set name: ' .. tostring(err))
    elseif current_name(p.b) ~= p.new then
        fail('#' .. p.num .. ': write did not stick (reads back ' ..
            "'" .. current_name(p.b) .. "')")
    else
        result.created[#result.created + 1] = { number = p.num, old = p.old, new = p.new }
    end
end

done()
