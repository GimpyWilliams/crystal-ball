-- livestock_intel.lua
--
-- READ-ONLY fortress intelligence for tame animals: census by species (sex,
-- pregnancy, training, productive traits) plus pen zone and nest-box counts.
-- Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>]).
-- Each section is wrapped in pcall so a field-name change in a future DF
-- version degrades that one section instead of breaking the whole report;
-- failures are reported under "errors".

-- Shared helpers come from scripts/_prelude.lua, prepended by intel.py.
if not report.fort_loaded then finish() return end

-- Readable species name from race id; falls back to creature_id string.
local function species_name(race_id)
    local name = 'unknown'
    pcall(function()
        local cr = df.global.world.raws.creatures.all[race_id]
        local n = cr.name[0]
        name = (n and n ~= '') and n or cr.creature_id
    end)
    return name
end

-- Productive / ancillary caste flags from ALL castes of a race so that per-sex
-- castes (e.g. MILKABLE only on the female caste) are captured correctly.
local function all_caste_flags(race_id)
    local f = {
        egg_layer = false, grazer = false, milkable = false, shearable = false,
        war_trainable = false, hunt_trainable = false, pack_animal = false,
        mount = false,
    }
    pcall(function()
        local craw = df.global.world.raws.creatures.all[race_id]
        for _, c in ipairs(craw.caste) do
            local cf = c.flags
            if cf.LAYS_EGGS         then f.egg_layer     = true end
            if cf.GRAZER            then f.grazer         = true end
            if cf.MILKABLE          then f.milkable       = true end
            if #c.shearable_tissue_layer > 0 then f.shearable = true end
            if cf.TRAINABLE_WAR     then f.war_trainable  = true end
            if cf.TRAINABLE_HUNTING then f.hunt_trainable = true end
            if cf.PACK_ANIMAL       then f.pack_animal    = true end
            if cf.MOUNT             then f.mount          = true end
        end
    end)
    return f
end

-- True when the unit is owned by a dwarf (i.e. is a pet).
local function is_pet(u)
    local pet = false
    pcall(function()
        for _, ref in ipairs(u.refs) do
            if df.general_ref_is_ownerst:is_instance(ref) then
                pet = true
                return
            end
        end
    end)
    return pet
end

-- 1. Per-species census of all tame animals owned by the fort.
section('tame_animals', function()
    local by_race = {}

    for _, u in ipairs(world.units.active) do
        local is_tame = false
        pcall(function()
            is_tame = dfhack.units.isActive(u)
                   and u.flags1.tame
                   and not dfhack.units.isCitizen(u)
        end)
        if not is_tame then goto continue end

        local race_id = u.race
        if not by_race[race_id] then
            local flags = all_caste_flags(race_id)
            by_race[race_id] = {
                species = species_name(race_id),
                race_id = race_id,
                female = 0, male = 0, unknown_sex = 0,
                pregnant = 0, pets = 0, marked_slaughter = 0,
                egg_layer     = flags.egg_layer,
                grazer        = flags.grazer,
                milkable      = flags.milkable,
                shearable     = flags.shearable,
                war_trainable = flags.war_trainable,
                hunt_trainable= flags.hunt_trainable,
                pack_animal   = flags.pack_animal,
                mount         = flags.mount,
                training_levels = {},
            }
        end

        local rec = by_race[race_id]

        -- Sex (0=female, 1=male, other=unknown)
        pcall(function()
            if u.sex == 0 then
                rec.female = rec.female + 1
            elseif u.sex == 1 then
                rec.male = rec.male + 1
            else
                rec.unknown_sex = rec.unknown_sex + 1
            end
        end)

        -- Pregnancy
        pcall(function()
            if u.pregnancy_timer and u.pregnancy_timer > 0 then
                rec.pregnant = rec.pregnant + 1
            end
        end)

        -- Pet status
        if is_pet(u) then rec.pets = rec.pets + 1 end

        -- Marked for slaughter
        pcall(function()
            if u.flags2.slaughter then
                rec.marked_slaughter = rec.marked_slaughter + 1
            end
        end)

        -- Training level
        pcall(function()
            local lvl = df.animal_training_level[u.training_level]
                     or tostring(u.training_level)
            rec.training_levels[lvl] = (rec.training_levels[lvl] or 0) + 1
        end)

        ::continue::
    end

    -- Flatten map to sorted array
    local animals = {}
    for _, rec in pairs(by_race) do
        animals[#animals + 1] = rec
    end
    table.sort(animals, function(a, b) return a.species < b.species end)
    report.tame_animals = animals
end)

-- 2. Count pen/pasture civzones (required for grazers).
section('pen_zones', function()
    local n = 0
    for _, b in ipairs(world.buildings.all) do
        if df.building_civzonest:is_instance(b)
                and b.type == df.civzone_type.Pen then
            n = n + 1
        end
    end
    report.pen_zones = n
end)

-- 3. Count built nest box furniture (required for egg-layers).
-- Fallback: if the furniture enum path fails, count NEST_BOX items instead.
section('nest_boxes', function()
    local n = 0
    local ok = pcall(function()
        for _, b in ipairs(world.buildings.all) do
            if df.building_furniturest:is_instance(b)
                    and b.type == df.furniture_type.NestBox then
                n = n + 1
            end
        end
    end)
    if not ok or n == 0 then
        pcall(function()
            local v = world.items.other.NEST_BOX
            if v then n = #v end
        end)
    end
    report.nest_boxes = n
end)

finish()
