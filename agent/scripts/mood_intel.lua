-- mood_intel.lua
--
-- READ-ONLY fort-wide strange-mood scanner. Finds every citizen currently in a
-- mood (Fey/Secretive/Possessed/Macabre/Fell + the insanity states) and, for the
-- productive ones, reads what their claimed workshop job still DEMANDS -- the same
-- "wants X" the game shows on the workshop screen -- then cross-references each
-- requirement against on-hand stock so the caller can see whether the material
-- actually exists, is reachable, or is stuck (uncollected web / forbidden / at the
-- depot). Mirrors DFHack's bundled showmood logic, with the stock cross-check
-- layered on via the shared classify_item() helper. Mutates NOTHING.
--
-- Shared helpers (matname/matdesc/classify_item/is_available) come from
-- scripts/_prelude.lua. Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end
report.moods = {}

-- Productive moods build an artifact/item and WILL turn to insanity if their
-- materials never arrive. The latter three are already-insane states (no job).
local PRODUCTIVE = { Fey = true, Secretive = true, Possessed = true,
                     Macabre = true, Fell = true }
local INSANE = { Melancholy = true, Raving = true, Berserk = true }

-- Generic material-class job_item flags we can map to a material flag, so a
-- "wants silk" filter can be tested against a candidate item's material. Keys are
-- df.job_item_flags{1,2} field names; values are df.material_flags field names.
-- Anything not listed degrades to "show the breakdown, don't claim a verdict".
local FLAG_TO_MATFLAG = {
    silk = 'SILK', yarn = 'YARN', leather = 'LEATHER', bone = 'BONE',
    shell = 'SHELL', tooth = 'TOOTH', horn = 'HORN', pearl = 'PEARL',
    totemable = 'TOTEMABLE', plant = 'THREAD_PLANT',
}

local function unit_name(u)
    local n
    pcall(function() n = dfhack.units.getReadableName(u) end)
    if n and n ~= '' then return n end
    pcall(function() n = dfhack.TranslateName(dfhack.units.getVisibleName(u)) end)
    return (n and n ~= '') and n or ('unit#' .. u.id)
end

local function profession(u)
    local p
    pcall(function() p = dfhack.units.getProfessionName(u) end)
    return p or '?'
end

-- The set material-class flag names on a job_item filter (e.g. {"silk"}).
local function jobitem_flag_tokens(jitem)
    local out = {}
    for _, field in ipairs({ 'flags1', 'flags2', 'flags3' }) do
        pcall(function()
            for name, val in pairs(jitem[field]) do
                if val == true then out[#out + 1] = name end
            end
        end)
    end
    return out
end

-- Human description of what a requirement filter wants: item type + material
-- (specific material name, else the generic flag tokens), matching the on-screen
-- demand ("cloth (silk)").
local function describe(jitem, tokens)
    local itype = '?'
    pcall(function()
        itype = (jitem.item_type >= 0)
            and (df.item_type[jitem.item_type] or tostring(jitem.item_type))
            or 'any item'
    end)
    local mat
    if jitem.mat_type and jitem.mat_type >= 0 then
        -- A generic INORGANIC class (mat_type 0, no specific index) on a BAR is
        -- what the game calls a "metal bar"; matname() would mislabel it "rock".
        if jitem.mat_type == 0 and (jitem.mat_index == nil or jitem.mat_index < 0)
           and itype == 'BAR' then
            mat = 'metal'
        else
            mat = matname(jitem.mat_type, jitem.mat_index)
        end
    elseif #tokens > 0 then
        mat = table.concat(tokens, '+')
    else
        mat = 'any'
    end
    return itype, mat
end

-- Does a concrete item satisfy this requirement's MATERIAL constraint? Specific
-- material -> exact compare; generic flag -> material-flag test; unknown -> nil
-- (can't say). Item-type match is handled by the caller scanning the right vector.
local function mat_matches(it, jitem, tokens)
    if jitem.mat_type and jitem.mat_type >= 0 then
        local ok = false
        pcall(function()
            ok = (it:getMaterial() == jitem.mat_type) and
                 (jitem.mat_index < 0 or it:getMaterialIndex() == jitem.mat_index)
        end)
        return ok
    end
    -- Generic: every mapped flag token must hold on the item's material.
    local mapped, verdict = false, true
    for _, tok in ipairs(tokens) do
        local mf = FLAG_TO_MATFLAG[tok]
        if mf and df.material_flags[mf] ~= nil then
            mapped = true
            local has = false
            pcall(function()
                local mi = dfhack.matinfo.decode(it)
                has = mi and mi.material and mi.material.flags[mf] or false
            end)
            if not has then verdict = false end
        end
    end
    if not mapped then return nil end   -- nothing we know how to test
    return verdict
end

-- Scan the stock vector for this requirement's item type, bucketing matching
-- units by availability/ownership using the shared classifier.
local function stock_for(itype_name, jitem, tokens)
    local r = { available = 0, locked = 0, unowned = 0,
                avail_by_mat = {}, unowned_by_state = {}, match_known = false }
    local vec = world.items.other[itype_name]
    if not vec then return r end
    for _, it in ipairs(vec) do
        pcall(function()
            local m = mat_matches(it, jitem, tokens)
            if m == nil then
                -- material untestable: count by item-type only (still useful)
                m = true
            else
                r.match_known = true
            end
            if not m then return end
            local st = classify_item(it)
            local n = it.stack_size
            if st == 'reachable' or st == 'in_container' then
                r.available = r.available + n
                local mat = matdesc(it)
                r.avail_by_mat[mat] = (r.avail_by_mat[mat] or 0) + n
            elseif st == 'forbidden' or st == 'dumped' or st == 'claimed_job'
                or st == 'carried' or st == 'melt' then
                r.locked = r.locked + n
            elseif st == 'uncollected_web' or st == 'loose_unreachable'
                or st == 'trade' then
                r.unowned = r.unowned + n
                r.unowned_by_state[st] = (r.unowned_by_state[st] or 0) + n
            end
        end)
    end
    return r
end

local function top_materials(tbl, k)
    local arr = {}
    for mat, n in pairs(tbl) do arr[#arr + 1] = { material = mat, units = n } end
    table.sort(arr, function(a, b) return a.units > b.units end)
    while #arr > (k or 4) do arr[#arr] = nil end
    return arr
end

-- The requirement-filter vector. DF version drift: older builds expose
-- job.job_items as a plain vector; current builds wrap it in a job_reqst struct
-- whose .elements holds the vector. Handle both.
local function job_item_list(job)
    local items = job.job_items
    if items == nil then return nil end
    local ok, el = pcall(function() return items.elements end)
    if ok and el ~= nil then return el end
    return items
end

-- Build the requirement list for one moody dwarf's job.
local function requirements_of(job)
    local reqs = {}
    local job_items, filled = job_item_list(job), {}
    if not job_items then return reqs, false end

    -- Tally already-attached items per requirement index (job.items[].job_item_idx).
    pcall(function()
        for _, ref in ipairs(job.items) do
            local idx = ref.job_item_idx
            if idx ~= nil and idx >= 0 then
                filled[idx] = (filled[idx] or 0) + 1
            end
        end
    end)

    local any_filled = false
    for i, jitem in ipairs(job_items) do
        local tokens = jobitem_flag_tokens(jitem)
        local itype, mat = describe(jitem, tokens)
        local need = jitem.quantity or 1
        local got = filled[i - 1] or 0          -- DFHack vectors are 0-based
        if got > 0 then any_filled = true end

        local req = { item_type = itype, material = mat,
                      qty_needed = need, qty_filled = got }

        if jitem.item_type and jitem.item_type >= 0 and got < need then
            local s = stock_for(itype, jitem, tokens)
            req.available = s.available
            req.locked = s.locked
            req.unowned = s.unowned
            req.by_material_available = top_materials(s.avail_by_mat, 4)
            req.unowned_by_state = s.unowned_by_state
            -- Satisfiable only when we could actually test the material match and
            -- enough reachable stock exists for the still-missing quantity.
            if s.match_known then
                req.satisfiable = (s.available >= (need - got))
            else
                req.satisfiable = nil   -- show the breakdown; don't claim a verdict
            end
        elseif got >= need then
            req.satisfiable = true       -- already attached
        end
        reqs[#reqs + 1] = req
    end
    return reqs, any_filled
end

for _, u in ipairs(world.units.active) do
    section('unit#' .. tostring(u.id), function()
        if not (u.mood and u.mood >= 0) then return end
        if not (dfhack.units.isCitizen(u) and dfhack.units.isActive(u)) then return end

        local mood = df.mood_type[u.mood] or tostring(u.mood)
        local m = { id = u.id, name = unit_name(u), profession = profession(u),
                    mood = mood, productive = PRODUCTIVE[mood] or false,
                    insane = INSANE[mood] or false, requirements = {} }

        local job = u.job.current_job
        if job then
            m.job = df.job_type[job.job_type] or tostring(job.job_type)
            -- The workshop the mood has claimed.
            pcall(function()
                local b = dfhack.job.getHolder(job)
                if b then
                    m.workshop = (df.building_type[b:getType()] or '?')
                    pcall(function()
                        local n = dfhack.buildings.getName(b)
                        if n and n ~= '' then m.workshop = n end
                    end)
                end
            end)
            local reqs, any_filled = requirements_of(job)
            m.requirements = reqs
            m.gathering = (#reqs > 0) and not any_filled or false
            local blocked = 0
            for _, r in ipairs(reqs) do
                if r.satisfiable == false then blocked = blocked + 1 end
            end
            m.blocked_count = blocked
        else
            m.job = 'none yet'
            m.gathering = true   -- claimed the mood, no job posted yet
        end

        report.moods[#report.moods + 1] = m
    end)
end

report.count = #report.moods
finish()
