-- world_agreements_intel.lua
--
-- READ-ONLY diplomatic agreements and entity relations. Probes multiple struct
-- paths for DF 50.x compatibility and reports which ones are accessible. Uses
-- prelude globals. Mutates NOTHING.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end

local function translate_entity_name(he)
    local nm = ''
    pcall(function()
        nm = dfhack.translation.translateName(he.name, true) or ''
        if nm == '' then nm = dfhack.translation.translateName(he.name) or '' end
    end)
    return (nm ~= '') and nm or nil
end

-- Subtype name for an (item_type, subtype) pair, e.g. WEAPON/subtype -> "iron
-- longsword". Returns nil for generic/-1 subtypes rather than guessing.
local function subtype_name(item_type, subtype)
    if subtype == nil or subtype < 0 then return nil end
    local nm = nil
    pcall(function()
        local sd = dfhack.items.getSubtypeDef(item_type, subtype)
        if sd then nm = sd.name end
    end)
    return nm
end

-- ---------------------------------------------------------------------------
-- Export/Import agreement decoding.
--
-- A liaison meeting's ExportAgreement/ImportAgreement events carry the actual
-- negotiated content:
--   - ExportAgreement.sell_prices: an entity_sell_prices struct with a `price`
--     field holding one vector<int32> per trade-good CATEGORY (Seeds, Wood,
--     MetalBars, Crafts, ...), each indexed by a category-specific material/
--     subtype slot. The whole table is pre-seeded with one uniform baseline
--     value (NOT always 100 -- one live fort showed 128), and only the entries
--     the negotiation actually singled out differ from it. So the baseline is
--     computed live per meeting (the statistical mode across every category)
--     rather than assumed, and only the differing entries are reported.
--   - ImportAgreement.buy_prices: an entity_buy_requests struct that is just a
--     flat list of concrete (item_type, subtype, material, priority) requests
--     -- no category/baseline indirection needed.
--
-- Category -> material resolvers below are wired ONLY for categories verified
-- live against a running fort this session (index order confirmed to match
-- historical_entity.resources sub-lists of the same length). Any other
-- category still gets reported (category name + slot index + value) -- it is
-- just not resolved to a material name, rather than guessing and risking a
-- wrong label.

local function organic_resolver(path)
    return function(entity, index)
        local ref = entity.resources
        for _, key in ipairs(path) do
            if ref == nil then return nil end
            ref = ref[key]
        end
        if ref == nil then return nil end
        local ok, mt, mi = pcall(function()
            return ref.mat_type[index], ref.mat_index[index]
        end)
        if not ok then return nil end
        return matname(mt, mi)
    end
end

-- Generic inorganic categories (stone/metal/gem) store a plain mat_index
-- vector against the implicit generic-inorganic mat_type (0).
local function inorganic_resolver(key)
    return function(entity, index)
        local ref = entity.resources[key]
        if ref == nil then return nil end
        local ok, mi = pcall(function() return ref[index] end)
        if not ok then return nil end
        return matname(0, mi)
    end
end

local CATEGORY_RESOLVERS = {
    Seeds        = organic_resolver({ 'seeds' }),
    ClothPlant   = organic_resolver({ 'plants' }),
    BagsPlant    = organic_resolver({ 'plants' }),
    ThreadPlant  = organic_resolver({ 'plants' }),
    RopesPlant   = organic_resolver({ 'plants' }),
    Powders      = organic_resolver({ 'misc_mat', 'powders' }),
    MetalBars    = inorganic_resolver('metals'),
    Stone        = inorganic_resolver('stones'),
    StoneBlocks  = inorganic_resolver('stones'),
    SmallCutGems = inorganic_resolver('gems'),
    LargeCutGems = inorganic_resolver('gems'),
}

-- entity: our OWN fort's historical_entity (these resource lists -- and the
-- agreement itself -- describe our goods, not the foreign counterpart's).
local function decode_sell_prices(entity, sp)
    if sp == nil then return nil end

    local cats = {}
    local counts = {}
    for cat, vec in pairs(sp.price) do
        local ok, n = pcall(function() return #vec end)
        if ok and n > 0 then
            cats[#cats + 1] = { name = cat, vec = vec, n = n }
            for i = 0, n - 1 do
                local v = vec[i]
                counts[v] = (counts[v] or 0) + 1
            end
        end
    end

    local baseline, baseline_n = nil, -1
    for v, c in pairs(counts) do
        if c > baseline_n then baseline, baseline_n = v, c end
    end

    local out = {}
    for _, cat in ipairs(cats) do
        local resolver = CATEGORY_RESOLVERS[cat.name]
        local entries = {}
        for i = 0, cat.n - 1 do
            local v = cat.vec[i]
            if v ~= baseline then
                local rec = { index = i, value = v }
                if resolver then
                    local ok, nm = pcall(resolver, entity, i)
                    if ok and nm then rec.material = nm end
                end
                entries[#entries + 1] = rec
            end
        end
        if #entries > 0 then
            out[#out + 1] = { category = cat.name, entries = entries }
        end
    end
    return { baseline = baseline, categories = out }
end

local function decode_buy_prices(bp)
    if bp == nil then return nil end
    local items = bp.items
    local out = {}
    for i = 0, #items.item_type - 1 do
        local it  = items.item_type[i]
        local ist = items.item_subtype[i]
        local mt  = items.mat_types[i]
        local mi  = items.mat_indices[i]
        local pri = items.priority[i]
        local rec = {
            item_type = tostring(df.item_type[it] or it),
            priority  = tonumber(pri) or pri,
        }
        local sn = subtype_name(it, ist)
        if sn then rec.item_subtype = sn end
        if mt ~= nil and mt >= 0 then rec.material = matname(mt, mi) end
        out[#out + 1] = rec
    end
    return out
end

-- PROBE: establish which global paths exist. Always runs so failures are
-- self-diagnosing even when every subsequent section errors out.
section('probe', function()
    local pr = {}

    -- Path A: world.diplomacy (primary in DF 50)
    local okA, errA = pcall(function()
        local d = df.global.world.diplomacy
        pr.diplomacy_type          = tostring(d)
        pr.diplomacy_entity_count  = #d.entities
    end)
    if not okA then pr.diplomacy_error = tostring(errA) end

    -- Path B: world.agreements (uncertain in DF 50) -- this is an
    -- agreement_handlerst struct, not a bare vector; the actual records live
    -- in its .all field. (world.agreements covers historical plots/schemes --
    -- e.g. PlotStealArtifact -- NOT trade; trade agreements live on
    -- plotinfo.dip_meeting_info, decoded below.)
    local okB, errB = pcall(function()
        local wa = df.global.world.agreements
        pr.agreements_type  = tostring(wa)
        pr.agreements_count = #wa.all
    end)
    if not okB then pr.agreements_error = tostring(errB) end

    -- Path C: world.world_data (alternate diplomacy subtree)
    local okC, errC = pcall(function()
        pr.world_data_type = tostring(df.global.world.world_data)
    end)
    if not okC then pr.world_data_error = tostring(errC) end

    report.probe = pr
end)

-- LIAISON MEETINGS: plotinfo.dip_meeting_info holds active liaison/diplomat
-- meetings. Each entry has the civ_id, diplomat histfig, and event log. This
-- is the primary diplomatic data source in this DFHack version, and where
-- Export/Import trade agreements actually show up (meeting_event.type 4/5).
section('diplomacy', function()
    local my_entity = df.historical_entity.find(df.global.plotinfo.civ_id)
    local meetings = {}
    for _, dmi in ipairs(df.global.plotinfo.dip_meeting_info) do
        pcall(function()
            local rec = {}
            pcall(function() rec.civ_id = dmi.civ_id end)
            pcall(function()
                local e = df.historical_entity.find(dmi.civ_id)
                if e then
                    rec.civ_name = translate_entity_name(e)
                    rec.civ_type = tostring(
                        df.historical_entity_type[e.type] or e.type)
                end
            end)
            pcall(function()
                local hf = df.historical_figure.find(dmi.diplomat_id)
                if hf then
                    rec.diplomat_name = translate_entity_name(hf)
                end
                rec.diplomat_id = dmi.diplomat_id
            end)
            pcall(function() rec.cur_step     = dmi.cur_step end)
            pcall(function() rec.events_count = #dmi.events end)
            -- Summarise events: type (decoded) and, for trade agreements, what
            -- was actually negotiated.
            local evts = {}
            pcall(function()
                for _, ev in ipairs(dmi.events) do
                    local er = {}
                    pcall(function() er.type = ev.type end)
                    pcall(function()
                        er.type_name = tostring(df.meeting_event_type[ev.type] or ev.type)
                    end)
                    pcall(function() er.year = ev.year end)
                    pcall(function() er.ticks = ev.ticks end)
                    pcall(function()
                        if ev.type == df.meeting_event_type.ExportAgreement then
                            er.export_agreement = decode_sell_prices(my_entity, ev.sell_prices)
                        elseif ev.type == df.meeting_event_type.ImportAgreement then
                            er.import_agreement = decode_buy_prices(ev.buy_prices)
                        end
                    end)
                    evts[#evts + 1] = er
                end
            end)
            rec.events = evts
            meetings[#meetings + 1] = rec
        end)
    end
    report.diplomacy_entities = meetings
end)

-- DIRECT AGREEMENTS: only meaningful if probe path B succeeded. Covers plots/
-- schemes (PlotStealArtifact, PlotAssassination, ...), not trade -- unrelated
-- to the liaison trade agreements decoded above. wa.all accumulates every
-- plot/scheme/citizenship request in world history (thousands by mid-game),
-- so only the most recent handful are decoded here -- a full dump would bloat
-- every report with almost entirely irrelevant historical noise.
local AGREEMENTS_DIRECT_LIMIT = 20
section('agreements_direct', function()
    local wa = df.global.world.agreements
    if wa == nil then return end
    local all = wa.all
    local n = #all
    local agreements = {}
    for i = math.max(0, n - AGREEMENTS_DIRECT_LIMIT), n - 1 do
        local a = all[i]
        pcall(function()
            local rec = {}
            pcall(function() rec.id = a.id end)
            pcall(function()
                local party_ids, histfig_ids = {}, {}
                for _, p in ipairs(a.parties or {}) do
                    for _, eid in ipairs(p.entity_ids or {}) do
                        party_ids[#party_ids + 1] = eid
                    end
                    for _, hfid in ipairs(p.histfig_ids or {}) do
                        histfig_ids[#histfig_ids + 1] = hfid
                    end
                end
                if #party_ids > 0 then rec.party_ids = party_ids end
                if #histfig_ids > 0 then rec.histfig_ids = histfig_ids end
            end)
            pcall(function()
                local d = a.details[0]
                if d then
                    rec.type_raw = tostring(df.agreement_details_type[d.type] or d.type)
                end
            end)
            agreements[#agreements + 1] = rec
        end)
    end
    report.agreements = agreements
    report.agreements_total = n
end)

finish()
