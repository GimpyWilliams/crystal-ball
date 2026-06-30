-- diagnose_textiles.lua
--
-- READ-ONLY root-cause analysis for "why aren't clothes being made?". Walks the
-- two-stage textile pipeline -- thread -> cloth (Loom) and cloth -> clothes
-- (Clothier's) -- and flags tattered clothing as the morale demand signal.
-- Mutates NOTHING. Shared helpers come from scripts/_prelude.lua.
--
-- Run via: RunCommand("lua", [<contents of this file>]).

if not report.fort_loaded then finish() return end
report.target = 'clothes'
report.facts = {}

-- Judge each stage on AVAILABLE (reachable & usable) stock, and when there is
-- none, point at what's merely acquirable (uncollected webs, unreachable cavern
-- thread, ...) so a starved chain reads as a real blocker with a next action --
-- instead of the old false "OK" on silk still stuck in a web.
local function stage(tname, noun)
    local s = stock_states(tname)
    local detail
    if s.available > 0 then
        detail = s.available .. ' ' .. noun .. ' available'
        if s.in_transit > 0 then
            detail = detail .. ' (+' .. s.in_transit .. ' in transit)'
        end
    else
        detail = '0 ' .. noun .. ' available'
        if s.acquirable > 0 then
            detail = detail .. ' -- but ' .. s.acquirable ..
                ' acquirable (uncollected/unreachable; run acquirable_items ' ..
                tname .. ')'
        end
    end
    return s, detail
end

-- Cloth stage: Loom + thread + a weaver.
local looms = workshops_of(df.workshop_type.Loom)
report.facts.looms = looms
add('loom_exists', looms > 0, 'blocker', looms .. ' loom(s) built')

local thread_s, thread_detail = stage('THREAD', 'thread to weave')
report.facts.thread_free = thread_s.available
add('thread_available', thread_s.available > 0, 'blocker', thread_detail)

local weaver_ok, weaver_detail = labor_check('WEAVER')
add('weaver_assigned', weaver_ok, 'blocker', 'weave (WEAVER): ' .. weaver_detail)

-- Clothes stage: Clothier's + cloth + a clothesmaker.
local clothiers = workshops_of(df.workshop_type.Clothiers)
report.facts.clothiers = clothiers
add('clothier_exists', clothiers > 0, 'blocker', clothiers .. " clothier's shop(s) built")

local cloth_s, cloth_detail = stage('CLOTH', 'cloth to sew')
report.facts.cloth_free = cloth_s.available
add('cloth_available', cloth_s.available > 0, 'blocker', cloth_detail)

local maker_ok, maker_detail = labor_check('CLOTHESMAKER')
add('clothesmaker_assigned', maker_ok, 'blocker',
    'sew (CLOTHESMAKER): ' .. maker_detail)

-- Demand signal: how much clothing is tattered (wear 3). Info, not a blocker --
-- it indicates whether the fort actually NEEDS more clothes made.
local tattered = 0
pcall(function()
    for _, tname in ipairs({ 'ARMOR', 'PANTS', 'SHOES', 'GLOVES', 'HELM' }) do
        local vec = world.items.other[tname]
        if vec then
            for _, it in ipairs(vec) do
                if (it.wear or 0) >= 3 then tattered = tattered + 1 end
            end
        end
    end
end)
report.facts.tattered_clothing = tattered
add('tattered_clothing', tattered == 0, 'info',
    tattered .. ' tattered clothing item(s) (high = dwarves need replacements)')

finish()
