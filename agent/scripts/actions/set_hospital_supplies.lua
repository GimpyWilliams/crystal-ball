-- scripts/actions/set_hospital_supplies.lua
--
-- Reversible write: adjust an EXISTING hospital location's desired-supply
-- maximums (contents.desired_*). This is the only zone/location write in the
-- project and it stays inside the locked safety model: it does NOT create,
-- delete, resize, or designate anything -- it only edits numbers a player edits
-- in the hospital UI, each trivially reversible (set the number back).
--
-- Input: first vararg is JSON {"hospital":"<name substr>","supplies":{"cloth":N,...}}.
-- `hospital` is optional; needed only to disambiguate when >1 hospital exists.
-- Validation (see actions/_prelude.lua discipline): the hospital must exist and
-- be unambiguous, every supply key must be whitelisted, every value a
-- non-negative integer -- all checked BEFORE any write; each write pcall-wrapped.
-- Output: {"ok":bool,"created":[{field,old,new}...],"errors":[...]}.
--
-- Run via: RunCommand("lua", [<prelude+this file>, <json spec>]).

if not (world.map.block_index ~= nil) then
    fail('no fortress is loaded')
    done()
    return
end

-- Whitelisted supply knobs -> contents field name. Nothing else is writable.
local SUPPLY_FIELD = {
    splints = 'desired_splints', thread = 'desired_thread',
    cloth = 'desired_cloth', crutches = 'desired_crutches',
    powder = 'desired_powder', buckets = 'desired_buckets',
    soap = 'desired_soap',
}

-- DF stores some supplies in internal "dimension" units, not whole items: the
-- desired_* field is items * dimension (e.g. 10 thread -> 150000). Callers pass
-- whole items (matching the in-game screen and zones_intel.lua's read), so we
-- multiply on write and divide reported old/new back to items. Keys absent here
-- are discrete (1:1): splints, crutches, buckets.
local SUPPLY_DIMENSION = {
    thread = 15000, cloth = 10000, powder = 150, soap = 150,
}

local function location_name(ab)
    local nm = ''
    pcall(function() nm = dfhack.translation.translateName(ab.name, true) end)
    return nm
end

local function hospitals()
    local site = dfhack.world.getCurrentSite()
    local out = {}
    if not site then return out end
    for _, ab in ipairs(site.buildings) do
        if df.abstract_building_hospitalst:is_instance(ab) then
            out[#out + 1] = ab
        end
    end
    return out
end

local spec = decode_spec(...)
if not spec then done() return end

-- 1. Resolve the target hospital.
local found = hospitals()
if #found == 0 then
    fail('no hospital location exists on this site (designate one in-game first)')
    done()
    return
end

local target
local sel = spec.hospital
if sel and sel ~= '' then
    local needle = string.lower(tostring(sel))
    local matches = {}
    for _, h in ipairs(found) do
        if string.find(string.lower(location_name(h)), needle, 1, true) then
            matches[#matches + 1] = h
        end
    end
    if #matches == 0 then
        fail('no hospital matches name ' .. tostring(sel))
        done() return
    elseif #matches > 1 then
        fail(#matches .. ' hospitals match ' .. tostring(sel) .. '; be more specific')
        done() return
    end
    target = matches[1]
elseif #found > 1 then
    fail(#found .. ' hospitals exist; pass hospital="<name substr>" to pick one')
    done() return
else
    target = found[1]
end

-- 2. Validate every requested supply BEFORE writing.
local supplies = spec.supplies or {}
local resolved = {}
local any = false
for key, val in pairs(supplies) do
    any = true
    local field = SUPPLY_FIELD[key]
    if not field then
        fail('unknown supply ' .. tostring(key) ..
            ' (allowed: splints/thread/cloth/crutches/powder/buckets/soap)')
    else
        local n = tonumber(val)
        if not n or n < 0 or n ~= math.floor(n) then
            fail(key .. ': maximum must be a non-negative integer (got ' ..
                tostring(val) .. ')')
        else
            resolved[#resolved + 1] = {
                key = key, field = field, new = math.floor(n),
                dim = SUPPLY_DIMENSION[key] or 1,
            }
        end
    end
end
if not any then fail('no supplies given to set') end

-- 3. Apply only the validated changes; each write pcall-wrapped and recorded.
local c = target.contents
for _, r in ipairs(resolved) do
    local ok, err = pcall(function()
        -- Caller speaks whole items; the struct field is items * dimension.
        local old = c[r.field]
        c[r.field] = r.new * r.dim
        result.created[#result.created + 1] = {
            field = r.key, old = math.floor(old / r.dim), new = r.new,
            hospital = location_name(target),
        }
    end)
    if not ok then fail('set ' .. r.key .. ': ' .. tostring(err)) end
end

done()
