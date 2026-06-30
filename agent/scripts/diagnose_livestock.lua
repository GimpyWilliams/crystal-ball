-- diagnose_livestock.lua
--
-- READ-ONLY root-cause analysis for "why aren't my animals breeding?".
-- Collects facts along the breeding pipeline (tame animals → both sexes →
-- pen zone for grazers → nest box for egg-layers) and runs deterministic
-- checks, each marked ok/not-ok with a short detail. Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

-- Shared helpers come from scripts/_prelude.lua, prepended by intel.py.
if not report.fort_loaded then finish() return end
report.target = 'livestock breeding'
report.facts  = {}

-- ── Collect all tame, non-citizen animals ──────────────────────────────────

local tame_units = {}
pcall(function()
    for _, u in ipairs(world.units.active) do
        local ok_tame = false
        pcall(function()
            ok_tame = dfhack.units.isActive(u)
                   and u.flags1.tame
                   and not dfhack.units.isCitizen(u)
        end)
        if ok_tame then tame_units[#tame_units + 1] = u end
    end
end)

local tame_count = #tame_units
report.facts.tame_count = tame_count

-- Productive/ancillary flags from ALL castes of a race.
local function all_caste_flags(race_id)
    local f = { egg_layer=false, grazer=false, milkable=false, shearable=false }
    pcall(function()
        local craw = df.global.world.raws.creatures.all[race_id]
        for _, c in ipairs(craw.caste) do
            local cf = c.flags
            if cf.LAYS_EGGS         then f.egg_layer  = true end
            if cf.GRAZER            then f.grazer      = true end
            if cf.MILKABLE          then f.milkable    = true end
            if #c.shearable_tissue_layer > 0 then f.shearable = true end
        end
    end)
    return f
end

local function species_name(race_id)
    local name = 'unknown'
    pcall(function()
        local cr = df.global.world.raws.creatures.all[race_id]
        local n = cr.name[0]
        name = (n and n ~= '') and n or cr.creature_id
    end)
    return name
end

-- ── Build per-species summary ───────────────────────────────────────────────

local by_race = {}  -- race_id → {female,male,is_grazer,is_egg_layer,is_productive,pet_female}

for _, u in ipairs(tame_units) do
    local race_id = u.race
    if not by_race[race_id] then
        local cf = all_caste_flags(race_id)
        by_race[race_id] = {
            female = 0, male = 0,
            is_grazer      = cf.grazer,
            is_egg_layer   = cf.egg_layer,
            is_productive  = cf.grazer or cf.egg_layer or cf.milkable or cf.shearable,
            pet_female     = 0,
        }
    end
    local rec = by_race[race_id]
    pcall(function()
        if u.sex == 0 then
            rec.female = rec.female + 1
        elseif u.sex == 1 then
            rec.male = rec.male + 1
        end
    end)
    -- Count females that are pets (owned by a dwarf)
    pcall(function()
        if u.sex == 0 then
            for _, ref in ipairs(u.refs) do
                if df.general_ref_is_ownerst:is_instance(ref) then
                    rec.pet_female = rec.pet_female + 1
                    break
                end
            end
        end
    end)
end

-- ── Checks ─────────────────────────────────────────────────────────────────

-- 1. Any tame animals at all?
add('has_tame_animals', tame_count > 0, 'blocker',
    tame_count .. ' tame animal(s) present')

-- 2. Productive species with >1 individual: do both sexes exist?
local missing_mate = {}
local productive_species_count = 0
local has_grazers    = false
local has_egg_layers = false

for race_id, rec in pairs(by_race) do
    if rec.is_grazer    then has_grazers    = true end
    if rec.is_egg_layer then has_egg_layers = true end
    if rec.is_productive and (rec.female + rec.male) > 1 then
        productive_species_count = productive_species_count + 1
        if rec.female == 0 or rec.male == 0 then
            missing_mate[#missing_mate + 1] =
                species_name(race_id) ..
                ': ' .. rec.female .. 'F/' .. rec.male .. 'M'
        end
    end
end

report.facts.productive_species_count = productive_species_count
report.facts.species_missing_mate     = #missing_mate

local pairs_ok = (#missing_mate == 0)
add('breeding_pairs', pairs_ok, 'blocker',
    pairs_ok
        and 'all productive species with >1 animal have both sexes'
        or  ('missing mate — ' .. table.concat(missing_mate, ', ')))

-- 3. Pen/pasture zone required for grazers?
local pen_count = 0
pcall(function()
    for _, b in ipairs(world.buildings.all) do
        if df.building_civzonest:is_instance(b)
                and b.type == df.civzone_type.Pen then
            pen_count = pen_count + 1
        end
    end
end)
report.facts.pen_zones = pen_count

if has_grazers then
    add('pen_zone_exists', pen_count > 0, 'blocker',
        pen_count .. ' pen/pasture zone(s); grazers need one to feed and breed')
else
    add('pen_zone_exists', true, 'info',
        'no grazing animals present — pen zones not required for breeding')
end

-- 4. Nest box required for egg-layers?
local nest_count = 0
local nest_ok = pcall(function()
    for _, b in ipairs(world.buildings.all) do
        if df.building_furniturest:is_instance(b)
                and b.type == df.furniture_type.NestBox then
            nest_count = nest_count + 1
        end
    end
end)
if not nest_ok or nest_count == 0 then
    pcall(function()
        local v = world.items.other.NEST_BOX
        if v then nest_count = #v end
    end)
end
report.facts.nest_boxes = nest_count

if has_egg_layers then
    add('nest_box_available', nest_count > 0, 'blocker',
        nest_count .. ' nest box(es); egg-layers need one to lay fertilized eggs')
else
    add('nest_box_available', true, 'info',
        'no egg-layers present — nest boxes not required for breeding')
end

-- 5. Animals at low training level (harder to pen/control, though still able to breed).
local low_training = 0
pcall(function()
    for _, u in ipairs(tame_units) do
        local lvl = 0
        pcall(function() lvl = u.training_level end)
        if lvl < 2 then low_training = low_training + 1 end
    end
end)
report.facts.untamed_count = low_training
add('training_level', low_training == 0, 'info',
    low_training > 0
        and (low_training .. ' animal(s) at wild/semi-wild level — harder to control but can still breed')
        or  'all animals at trained level or above')

-- 6. All females of a productive species assigned as pets? (may skip the pen)
local all_pet_species = {}
for race_id, rec in pairs(by_race) do
    if rec.is_productive and rec.female > 0
            and rec.pet_female >= rec.female then
        all_pet_species[#all_pet_species + 1] = species_name(race_id)
    end
end
table.sort(all_pet_species)
local all_pets_ok = (#all_pet_species == 0)
add('productive_all_pets', all_pets_ok, 'info',
    all_pets_ok
        and 'no productive species has all its females assigned as pets'
        or  ('all females are pets (may roam instead of using pen): '
             .. table.concat(all_pet_species, ', ')))

finish()
