"""
MCP server exposing READ-ONLY fortress industry & subsystem intel from a live
Dwarf Fortress + DFHack instance: per-industry status + root-cause diagnosis for
brewing, cooking, farming, fishing, butchery, textiles, metal, fuel, construction,
medical and justice, plus fort-wide stock, storage, workshop/order, dwarf and
announcement views. (Brewing was the original focus; the server is now general.)

Transport is stdio: an MCP client (e.g. Claude Desktop / Claude Code) launches
this file as a subprocess and talks over stdin/stdout. There is NO network
listener -- nothing binds a port. The only outbound connection made by this
process is the loopback DFHack RPC socket on 127.0.0.1:5000.

Almost every tool here is read-only. The exception is a small, clearly-delimited
set of "act" tools (queue_work_order, auto_stock_target, fix_idle,
manage_containers, boost_mood) that can create manager orders -- but only when
called with mode='apply' AND confirm=True. In their default mode they are
read-only (advise/preview). All writes go through actions.run_action(), which
runs only audited mutation scripts and validates every enum before mutating. No
further write tools must be added without explicit instruction.

Run standalone for a quick check:
    python mcp_server.py --selftest
"""

import sys

from mcp.server.fastmcp import FastMCP

from brewery import fetch_brewing_intel, format_report
from diagnostics import fetch_brewing_diagnosis, format_brewing_diagnosis
from food import (
    fetch_butchery_diagnosis,
    fetch_butchery_intel,
    fetch_cooking_diagnosis,
    fetch_cooking_intel,
    fetch_farming_diagnosis,
    fetch_farming_intel,
    fetch_fishing_diagnosis,
    fetch_fishing_intel,
    format_butchery_diagnosis,
    format_butchery_report,
    format_cooking_diagnosis,
    format_cooking_report,
    format_farming_diagnosis,
    format_farming_report,
    format_fishing_diagnosis,
    format_fishing_report,
)
from textiles import (
    fetch_textiles_diagnosis,
    fetch_textiles_intel,
    format_textiles_diagnosis,
    format_textiles_report,
)
from metalworks import (
    fetch_fuel_diagnosis,
    fetch_fuel_intel,
    fetch_metal_diagnosis,
    fetch_metal_intel,
    format_fuel_diagnosis,
    format_fuel_report,
    format_metal_diagnosis,
    format_metal_report,
)
from construction import (
    fetch_construction_diagnosis,
    fetch_construction_intel,
    format_construction_diagnosis,
    format_construction_report,
)
from medical import (
    fetch_medical_diagnosis,
    fetch_medical_intel,
    format_medical_diagnosis,
    format_medical_report,
)
from justice import (
    fetch_justice_diagnosis,
    fetch_justice_intel,
    format_justice_diagnosis,
    format_justice_report,
)
from livestock import (
    fetch_livestock_diagnosis,
    fetch_livestock_intel,
    format_livestock_diagnosis,
    format_livestock_report,
)
from zones import fetch_zones_intel, format_zones_report
from hotkeys import fetch_hotkeys_intel, format_hotkeys_report
from legends import (
    fetch_artifact,
    fetch_deity,
    fetch_faith,
    format_artifact,
    format_deity,
    format_faith,
)
from dwarves import (
    fetch_bedroom_assignments,
    fetch_dwarf_detail,
    fetch_labor_coverage,
    fetch_roster,
    format_bedroom_assignments,
    format_dwarf_detail,
    format_labor_coverage,
    format_roster,
)
from mood import fetch_mood, format_mood
from briefing import fetch_briefing, format_briefing
from pipelines import (
    fetch_acquirable,
    fetch_building_config,
    fetch_building_locate,
    fetch_containers,
    fetch_item_detail,
    fetch_shops_and_orders,
    fetch_stock,
    fetch_stockpile_config,
    fetch_stockpile_locate,
    format_acquirable,
    format_building_config,
    format_building_locate,
    format_containers,
    format_item_detail,
    format_shops_and_orders,
    format_stock,
    format_stockpile_config,
    format_stockpile_locate,
)
from announcements import fetch_announcements, format_announcements
from trade import (
    fetch_caravan_intel,
    fetch_trade_history,
    format_caravan_report,
    format_trade_history_report,
)
from agreements import fetch_agreements_intel, format_agreements_report
from mutations import (
    auto_stock_target as _auto_stock_target,
    boost_mood as _boost_mood,
    fix_idle as _fix_idle,
    manage_containers as _manage_containers,
    queue_work_order as _queue_work_order,
    set_hospital_supplies as _set_hospital_supplies,
    set_hotkey as _set_hotkey,
)
from dfhack_rpc.client import DFHackError

mcp = FastMCP("crystal-ball")


def _safe(fmt, fetch):
    """Run a fetch+format pair, turning connection errors into a message."""
    try:
        return fmt(fetch())
    except DFHackError as e:
        return f"Could not read fortress data: {e}"


@mcp.tool()
def fort_briefing() -> str:
    """One batched 'morning briefing' for the loaded fort: citizen/stress
    summary, active strange moods (with insanity-risk flags), hospital and
    caregiver status, workshop idle/busy + active order counts, key survival
    stocks (drinks/food/plants/...), and a cross-industry roll-up of flagged
    blockers from every diagnose_* pipeline. Runs all sections over ONE shared
    DFHack connection (cheaper than calling each report separately). Read-only;
    a good first call when you load the game."""
    return _safe(format_briefing, fetch_briefing)


@mcp.tool()
def fort_briefing_data() -> dict:
    """Same morning briefing as structured JSON (roster, moods, medical, shops,
    stock, blockers[], section_errors[]). Read-only."""
    return fetch_briefing()


@mcp.tool()
def brewing_report() -> str:
    """Get a plain-text beer/alcohol production status report for the
    currently loaded Dwarf Fortress fort: drinks on hand, empty barrels and
    large pots, idle/working stills, active brew work orders, and brewable
    raw plants in stock. Read-only; does not change anything in the game."""
    return _safe(format_report, fetch_brewing_intel)


@mcp.tool()
def brewing_data() -> dict:
    """Get the same beer-production status as structured JSON data (drinks,
    empty_containers, stills, brew_orders, plants). Read-only."""
    return fetch_brewing_intel()


@mcp.tool()
def cooking_report() -> str:
    """Plain-text kitchen/cooking status for the loaded fort: prepared meals on
    hand, cookable ingredients (free vs total, by item type) with a distinct-type
    count for meal variety, idle/working kitchens, and active cook work orders.
    Read-only; does not change anything in the game."""
    return _safe(format_cooking_report, fetch_cooking_intel)


@mcp.tool()
def cooking_data() -> dict:
    """Same kitchen/cooking status as structured JSON (meals, ingredients,
    kitchens, cook_orders). Read-only."""
    return fetch_cooking_intel()


@mcp.tool()
def diagnose_cooking() -> str:
    """Root-cause analysis for 'why isn't anyone cooking meals?'. Walks the
    cooking pipeline (order queued -> kitchen built/free -> cookable ingredients
    on hand -> at least 2 distinct ingredient types -> a dwarf able to cook) and
    returns a ranked list of likely blockers plus the underlying facts.
    Read-only; gathers facts only."""
    return _safe(format_cooking_diagnosis, fetch_cooking_diagnosis)


@mcp.tool()
def diagnose_cooking_data() -> dict:
    """Same cooking diagnosis as structured JSON (checks[] with ok/severity,
    plus facts{}). Read-only."""
    return fetch_cooking_diagnosis()


@mcp.tool()
def farming_report() -> str:
    """Plain-text farming status for the loaded fort: current season, farm plots
    (count/tiles and how many are planted this season), what crop each plot is
    set to grow now with seed availability, and seeds on hand by crop. Read-only;
    does not change anything in the game."""
    return _safe(format_farming_report, fetch_farming_intel)


@mcp.tool()
def farming_data() -> dict:
    """Same farming status as structured JSON (season, plots, seeds). Read-only."""
    return fetch_farming_intel()


@mcp.tool()
def diagnose_farming() -> str:
    """Root-cause analysis for 'why aren't crops being planted?'. Walks the
    farming pipeline (plot built -> crop set for the current season -> seeds for
    that crop on hand -> a dwarf able to farm) and returns a ranked list of
    likely blockers plus the underlying facts. Read-only; gathers facts only."""
    return _safe(format_farming_diagnosis, fetch_farming_diagnosis)


@mcp.tool()
def diagnose_farming_data() -> dict:
    """Same farming diagnosis as structured JSON (checks[] with ok/severity,
    plus facts{}). Read-only."""
    return fetch_farming_diagnosis()


@mcp.tool()
def fishing_report() -> str:
    """Plain-text fishing status for the loaded fort: edible fish on hand (by
    material), raw fish waiting to be cleaned, idle/working fisheries, and active
    clean-fish work orders. Read-only; does not change anything in the game."""
    return _safe(format_fishing_report, fetch_fishing_intel)


@mcp.tool()
def fishing_data() -> dict:
    """Same fishing status as structured JSON (fish, raw_fish, fisheries,
    clean_orders). Read-only."""
    return fetch_fishing_intel()


@mcp.tool()
def diagnose_fishing() -> str:
    """Root-cause analysis for 'why isn't fish food being produced?'. Walks the
    fishing pipeline (catch raw fish -> fishery built/free -> clean into edible
    fish -> dwarves able to catch and to clean) and returns a ranked list of
    likely blockers plus the underlying facts. Read-only; gathers facts only."""
    return _safe(format_fishing_diagnosis, fetch_fishing_diagnosis)


@mcp.tool()
def diagnose_fishing_data() -> dict:
    """Same fishing diagnosis as structured JSON (checks[] with ok/severity,
    plus facts{}). Read-only."""
    return fetch_fishing_diagnosis()


@mcp.tool()
def butchery_report() -> str:
    """Plain-text butchery/tanning status for the loaded fort: animals marked for
    slaughter, butcherable corpses, idle/working butcher's shops, meat and fat on
    hand, plus a tanning sub-view (tanneries and leather on hand). Read-only;
    does not change anything in the game."""
    return _safe(format_butchery_report, fetch_butchery_intel)


@mcp.tool()
def butchery_data() -> dict:
    """Same butchery/tanning status as structured JSON (marked_for_slaughter,
    corpses, butcher_shops, output, tanning, butcher_orders). Read-only."""
    return fetch_butchery_intel()


@mcp.tool()
def diagnose_butchery() -> str:
    """Root-cause analysis for 'why isn't anything being butchered?'. Walks the
    butchery pipeline (animal marked for slaughter or a corpse on hand ->
    butcher's shop built/free -> a dwarf able to butcher) with tanning as
    secondary context, and returns a ranked list of likely blockers plus the
    underlying facts. Read-only; gathers facts only."""
    return _safe(format_butchery_diagnosis, fetch_butchery_diagnosis)


@mcp.tool()
def diagnose_butchery_data() -> dict:
    """Same butchery diagnosis as structured JSON (checks[] with ok/severity,
    plus facts{}). Read-only."""
    return fetch_butchery_diagnosis()


@mcp.tool()
def livestock_report() -> str:
    """Plain-text tame animal census for the loaded fort: all tame animals
    grouped as productive (grazers, egg-layers, milkable, shearable) and other
    (dogs, cats, war/pack/mount animals, exotic pets), with per-species sex
    counts, pregnancy, training level, trait tags, and inline warnings for
    missing mates, egg-layers with no nest box, and grazers with no pen zone.
    Footer shows pen zone and nest box counts. Read-only."""
    return _safe(format_livestock_report, fetch_livestock_intel)


@mcp.tool()
def livestock_data() -> dict:
    """Same tame animal census as structured JSON (tame_animals[], pen_zones,
    nest_boxes). Each species entry carries female/male/unknown_sex/pregnant/
    pets/marked_slaughter counts, boolean caste flags (egg_layer, grazer,
    milkable, shearable, war_trainable, hunt_trainable, pack_animal, mount),
    and a training_levels breakdown. Read-only."""
    return fetch_livestock_intel()


@mcp.tool()
def diagnose_livestock() -> str:
    """Root-cause analysis for 'why aren't my animals breeding?'. Walks the
    breeding pipeline (tame animals present -> both sexes for productive species
    -> pen zone for grazers -> nest box for egg-layers) and returns a ranked
    list of likely blockers plus the underlying facts. Read-only."""
    return _safe(format_livestock_diagnosis, fetch_livestock_diagnosis)


@mcp.tool()
def diagnose_livestock_data() -> dict:
    """Same livestock breeding diagnosis as structured JSON (checks[] with
    ok/severity/detail, plus facts{}). Read-only."""
    return fetch_livestock_diagnosis()


@mcp.tool()
def textiles_report() -> str:
    """Plain-text textiles/clothing status for the loaded fort: thread and cloth
    leading with what the fort OWNS (on hand) and listing not-yet-acquired stock
    (uncollected webs / trade goods / unreachable) separately, clothing on hand
    by type with tattered/worn counts, looms and clothier's shops, and weave/sew
    orders.
    AVAILABLE = usable by a job now; ON_HAND = everything the fort owns;
    NOT_YET_ACQUIRED = silk still in webs, caravan goods, unreachable items --
    these are POTENTIAL, not stock. When asked 'how much thread do I have',
    answer with on_hand (or available), NEVER the gross total. Read-only."""
    return _safe(format_textiles_report, fetch_textiles_intel)


@mcp.tool()
def textiles_data() -> dict:
    """Same textiles status as structured JSON (thread, cloth, clothing, looms,
    clothiers, orders). Thread/cloth carry available, in_transit, owned_unavailable,
    inert, on_hand, not_yet_acquired, and total (= on_hand + not_yet_acquired).
    on_hand is what the fort owns; not_yet_acquired (uncollected webs / trade /
    unreachable) is potential, not stock -- never report total as 'what I have'.
    Read-only."""
    return fetch_textiles_intel()


@mcp.tool()
def diagnose_textiles() -> str:
    """Root-cause analysis for 'why aren't clothes being made?'. Walks the two
    stages -- thread -> cloth (loom) and cloth -> clothes (clothier's) -- checking
    workshop, materials, and labor at each, and flags tattered clothing as the
    demand signal. Read-only; gathers facts only."""
    return _safe(format_textiles_diagnosis, fetch_textiles_diagnosis)


@mcp.tool()
def diagnose_textiles_data() -> dict:
    """Same textiles diagnosis as structured JSON (checks[], facts{}). Read-only."""
    return fetch_textiles_diagnosis()


@mcp.tool()
def metal_report() -> str:
    """Plain-text metal-industry status for the loaded fort: metal ore on hand by
    material, metal bars (and fuel on hand), smelters and forges (with magma
    counts), and smelt/forge orders. Read-only."""
    return _safe(format_metal_report, fetch_metal_intel)


@mcp.tool()
def metal_data() -> dict:
    """Same metal status as structured JSON (ore, bars, smelters, forges,
    orders). Read-only."""
    return fetch_metal_intel()


@mcp.tool()
def diagnose_metal() -> str:
    """Root-cause analysis for 'why isn't metal being made?'. Walks the smelting
    pipeline (smelter built -> ore on hand -> fuel, unless a magma smelter ->
    a dwarf able to smelt) with forging as secondary context, and returns ranked
    blockers plus facts. Read-only; gathers facts only."""
    return _safe(format_metal_diagnosis, fetch_metal_diagnosis)


@mcp.tool()
def diagnose_metal_data() -> dict:
    """Same metal diagnosis as structured JSON (checks[], facts{}). Read-only."""
    return fetch_metal_diagnosis()


@mcp.tool()
def fuel_report() -> str:
    """Plain-text fuel status for the loaded fort: charcoal/coke on hand, logs on
    hand, wood furnaces, any magma smelters/forges (which need no charcoal), and
    charcoal orders. Read-only."""
    return _safe(format_fuel_report, fetch_fuel_intel)


@mcp.tool()
def fuel_data() -> dict:
    """Same fuel status as structured JSON (fuel, wood, wood_furnaces, magma,
    charcoal_orders_left). Read-only."""
    return fetch_fuel_intel()


@mcp.tool()
def diagnose_fuel() -> str:
    """Root-cause analysis for 'why isn't charcoal being made?'. Walks the
    charcoal pipeline (wood furnace built -> logs on hand -> a dwarf able to burn
    wood) and notes when magma makes fuel optional. Read-only; gathers facts."""
    return _safe(format_fuel_diagnosis, fetch_fuel_diagnosis)


@mcp.tool()
def diagnose_fuel_data() -> dict:
    """Same fuel diagnosis as structured JSON (checks[], facts{}). Read-only."""
    return fetch_fuel_diagnosis()


@mcp.tool()
def construction_report() -> str:
    """Plain-text building-materials status for the loaded fort across masonry
    (stone->blocks), carpentry (logs->furniture), glass (sand->raw glass), and
    mechanisms (stone->mechanisms): workshops, inputs/outputs on hand, and
    orders. Read-only."""
    return _safe(format_construction_report, fetch_construction_intel)


@mcp.tool()
def construction_data() -> dict:
    """Same construction status as structured JSON (masonry, carpentry, glass,
    mechanisms, orders). Read-only."""
    return fetch_construction_intel()


@mcp.tool()
def diagnose_construction() -> str:
    """Root-cause analysis for the building-materials industries. Reports, per
    sub-industry (masonry/carpentry/glass/mechanisms), whether its workshop,
    input material, and labor are present, so you can see which chain is stalled
    and why. Read-only; gathers facts only."""
    return _safe(format_construction_diagnosis, fetch_construction_diagnosis)


@mcp.tool()
def diagnose_construction_data() -> dict:
    """Same construction diagnosis as structured JSON (checks[], facts{}).
    Read-only."""
    return fetch_construction_diagnosis()


@mcp.tool()
def medical_report() -> str:
    """Plain-text hospital/medical status for the loaded fort: hospital zones,
    citizens needing healthcare, caregiver labor coverage (diagnosis/surgery/
    bone-setting/suturing/wound-dressing), and supplies (splints, crutches,
    cloth, thread, buckets). Read-only."""
    return _safe(format_medical_report, fetch_medical_intel)


@mcp.tool()
def medical_data() -> dict:
    """Same medical status as structured JSON (hospitals, wounded, caregivers,
    supplies). Read-only."""
    return fetch_medical_intel()


@mcp.tool()
def diagnose_medical() -> str:
    """Root-cause analysis for 'can my wounded be treated?'. Checks for a
    hospital zone, a diagnostician and treatment labors, and basic supplies,
    surfacing the wounded count as context. Read-only; gathers facts only."""
    return _safe(format_medical_diagnosis, fetch_medical_diagnosis)


@mcp.tool()
def diagnose_medical_data() -> dict:
    """Same medical diagnosis as structured JSON (checks[], facts{}). Read-only."""
    return fetch_medical_diagnosis()


@mcp.tool()
def zones_report() -> str:
    """Plain-text zones & locations status for the loaded fort. Lists the fort's
    LOCATIONS (taverns, temples, hospitals, libraries, guildhalls) by name -- a
    hospital is a location here, NOT a civzone -- with hospital supply maximums
    (stocked/max for splints, thread, cloth, crutches, powder, buckets, soap),
    plus a by-type count of raw civzones (bedrooms, dining halls, ...).
    Read-only."""
    return _safe(format_zones_report, fetch_zones_intel)


@mcp.tool()
def zones_data() -> dict:
    """Same zones & locations status as structured JSON (locations[], civzones).
    Read-only."""
    return fetch_zones_intel()


@mcp.tool()
def justice_report() -> str:
    """Plain-text justice status for the loaded fort: law-enforcement positions
    (sheriff / captain of the guard) with filled/vacant status, and the number of
    crimes logged. Read-only."""
    return _safe(format_justice_report, fetch_justice_intel)


@mcp.tool()
def justice_data() -> dict:
    """Same justice status as structured JSON (law_enforcement, crimes_logged).
    Read-only."""
    return fetch_justice_intel()


@mcp.tool()
def diagnose_justice() -> str:
    """Root-cause analysis for 'is fortress justice functioning?'. Checks that a
    law-enforcement official (sheriff / captain of the guard) is defined and
    appointed so crimes can be investigated and punished, with the crime caseload
    as context. Read-only; gathers facts only."""
    return _safe(format_justice_diagnosis, fetch_justice_diagnosis)


@mcp.tool()
def diagnose_justice_data() -> dict:
    """Same justice diagnosis as structured JSON (checks[], facts{}). Read-only."""
    return fetch_justice_diagnosis()


@mcp.tool()
def stock_report(item_type: str = "") -> str:
    """Generic stock inventory across the whole fort, for troubleshooting any
    industrial pipeline (not just beer). Lists every item type (DRINK, PLANT,
    BAR, WOOD, CLOTH, ...) leading with on-hand stock (available + in transit +
    owned-but-locked + inert) and a per-material breakdown, with not-yet-acquired
    stock (uncollected webs / trade goods / unreachable) shown separately.
    When asked 'how much X do I have', answer with on_hand (or available), NEVER
    the gross total -- the total folds in items the fort does not own yet.
    Pass `item_type` (free text: 'DRINK', 'TOOL', or a subtype like 'nest box')
    to scan ONLY that type -- far faster than the whole-fort scan and, for a type
    with subtypes, itemized by subtype. Omit for the full inventory. Read-only."""
    return _safe(format_stock, lambda: fetch_stock(item_type or None))


@mcp.tool()
def stock_data(item_type: str = "") -> dict:
    """Same generic stock inventory as structured JSON. Each category carries
    free_units (= available now), in_transit, owned_unavailable, inert, on_hand,
    not_yet_acquired, total_units (gross = on_hand + not_yet_acquired), plus
    by_material / by_material_on_hand / by_material_unowned (and by_subtype when
    focused). on_hand is what the fort owns; not_yet_acquired (webs / trade /
    unreachable) is potential, not stock -- never report total_units as 'what I
    have'. Pass `item_type` (free text) to scan one type only -- recommended, as
    the unfocused JSON can be very large. Read-only."""
    return fetch_stock(item_type or None)


@mcp.tool()
def container_report() -> str:
    """Audit storage containers (barrels, large pots, bins, bags, chests): per
    kind, how many are empty / partly full / (nearly) full, the average fill %,
    and how many are forbidden -- capacity-aware (by contained volume), not just
    'has something in it'. Bags (critical for sand/flour/gypsum/seeds) are split
    out from wooden chests/coffers. Lists the nearly-full containers with their
    stockpile and coordinates. Use when output 'won't store' or a pipeline stalls
    for lack of empty containers ('none empty' flags the starved kind). Read-only."""
    return _safe(format_containers, fetch_containers)


@mcp.tool()
def container_data() -> dict:
    """Same container/storage audit as structured JSON: per kind {total, empty,
    partial, full, forbidden, avg_fill_pct} for barrels/large_pots/bins/bags/
    chests, plus attention[{kind, fill_pct, material, where, pos}] for the
    nearly-full containers. Read-only."""
    return fetch_containers()


@mcp.tool()
def shops_and_orders_report() -> str:
    """List every workshop/furnace grouped by type (idle/busy/suspended job
    counts) and every manager work order with remaining amount and status.
    Answers 'do I have a free workshop?' and 'is my order actually active?'.
    Read-only."""
    return _safe(format_shops_and_orders, fetch_shops_and_orders)


@mcp.tool()
def shops_and_orders_data() -> dict:
    """Same workshops + manager-orders view as structured JSON. Read-only."""
    return fetch_shops_and_orders()


@mcp.tool()
def stockpile_locate(item_type: str) -> str:
    """Find where items of a given kind are -- stockpiles, containers, buildings,
    carried by a dwarf, or loose on the ground. `item_type` accepts free text:
    a df.item_type name ('THREAD', 'DRINK') OR a specific subtype by its human
    name or raw id ('nest box', 'jug', 'wheelbarrow', 'iron breastplate',
    'ITEM_TOOL_NEST_BOX') -- the subtype is resolved against the world's raws so
    a query for one of the ~30 things that share item_type TOOL returns just that
    thing. When few match, lists each with exact (x,y,z) coordinates; when many,
    falls back to a per-location summary with a z-level scatter. An unknown name
    returns a suggestion instead of an error. Read-only."""
    try:
        return format_stockpile_locate(fetch_stockpile_locate(item_type))
    except DFHackError as e:
        return f"Could not read fortress data: {e}"


@mcp.tool()
def stockpile_locate_data(item_type: str) -> dict:
    """Same location lookup as structured JSON (query, resolved_type,
    resolved_subtype, total_items, total_units, locations[{label, pos,
    item_count, stack_units}], items[{pos, where, n}] per-instance detail,
    ground scatter). `item_type` is free text (see stockpile_locate). Read-only."""
    return fetch_stockpile_locate(item_type)


@mcp.tool()
def building_locate(building_type: str) -> str:
    """Find where BUILDINGS of a given type are, with positions. `building_type`
    accepts free text: a df.building_type name ('Bridge', 'Well', 'Floodgate',
    'NestBox') OR a workshop/furnace/trap subtype by name ('Masons', 'Smelter',
    'Lever') -- resolved against the world's raws. Answers "where are my levers /
    floodgates / wells / altars / a specific workshop?", which shops_and_orders
    (counts only) and zones (civzones/locations only) do not. When few match,
    lists each with exact (x,y,z), build stage, and current job; when many, gives
    a by-subtype summary. Iterates buildings directly (no per-tile scan).
    An unknown name returns a suggestion. Read-only."""
    try:
        return format_building_locate(fetch_building_locate(building_type))
    except DFHackError as e:
        return f"Could not read fortress data: {e}"


@mcp.tool()
def building_locate_data(building_type: str) -> dict:
    """Same building lookup as structured JSON (query, resolved_type,
    resolved_subtype, total, built, busy, items[{pos, subtype, built, busy,
    job}], by_subtype{}). `building_type` is free text (see building_locate).
    Read-only."""
    return fetch_building_locate(building_type)


@mcp.tool()
def stockpile_config() -> str:
    """Report each stockpile's CONFIGURATION (not its contents): which item
    categories it accepts, its give/take links to other piles, and -- where the
    build exposes them -- bin/barrel/wheelbarrow caps. The 'why won't my output
    store here / why is this pile pulling from there' lens that stockpile_locate
    and container_report (contents only) miss. Read-only."""
    return _safe(format_stockpile_config, fetch_stockpile_config)


@mcp.tool()
def stockpile_config_data() -> dict:
    """Same stockpile configuration as structured JSON (stockpiles[{number,
    name, pos, accepts[], links_give, links_take, max_bins, max_barrels,
    max_wheelbarrows}]). Read-only."""
    return fetch_stockpile_config()


@mcp.tool()
def building_config() -> str:
    """Report zone/room ASSIGNMENTS: which civzones (bedrooms, offices, dining
    halls, tombs, pastures, ...) are assigned to a specific unit, plus a by-type
    assigned/total tally. In DF v50 a room's owner lives on the civzone
    (assigned_unit_id), not the furniture; this generalizes the bedroom-only
    view to every assignable zone type. Read-only."""
    return _safe(format_building_config, fetch_building_config)


@mcp.tool()
def building_config_data() -> dict:
    """Same zone/room assignments as structured JSON (assignments[{zone_type,
    pos, unit_id, unit}], by_type{ztype: {assigned, unassigned}}). Read-only."""
    return fetch_building_config()


@mcp.tool()
def item_detail(item_id: int) -> str:
    """Inspect ONE item by its numeric id: type/subtype, material, quality, wear,
    stack size, where it is (tile / container / carrier), the job reserving it,
    its notable flags, and its availability verdict (reachable / forbidden /
    in_transit / carried / ...). Answers 'what exactly is item #N and why isn't
    it usable'. Item ids come from stockpile_locate_data (items[].id) or
    artifact_locate. Read-only."""
    try:
        return format_item_detail(fetch_item_detail(item_id))
    except DFHackError as e:
        return f"Could not read fortress data: {e}"


@mcp.tool()
def item_detail_data(item_id: int) -> dict:
    """Same single-item inspection as structured JSON (item{id, type, subtype,
    material, quality, wear, stack_size, state, pos, container, holder, job,
    flags}). Read-only."""
    return fetch_item_detail(item_id)


@mcp.tool()
def acquirable_items(item_type: str = "") -> str:
    """The inverse of the 'available stock' reports: items that are NOT freely
    available to a workshop now but COULD be recovered -- uncollected spider
    webs (need Collect Webs), cargo on a (possibly stranded) hauler, stock loose
    on the ground or deep in the caverns (needs a hauler / a path), items claimed
    by a job, and items one designation away (forbidden / dumped / marked for
    trade). Buckets are grouped into 'owned but locked' (recover with a flag
    toggle or a finished job) vs 'not owned yet' (gather / trade / dig to
    acquire) -- this is the acquisition side of the available-vs-acquired split.
    Each bucket carries a 'how to get it' hint, ground scatter by z-level, and a
    state histogram so available + in-transit + acquirable + inert reconciles to
    the total. Pass an item_type (e.g. 'THREAD') to focus, or omit for a
    fort-wide roll-up. Read-only."""
    try:
        return format_acquirable(fetch_acquirable(item_type or None))
    except DFHackError as e:
        return f"Could not read fortress data: {e}"


@mcp.tool()
def acquirable_items_data(item_type: str = "") -> dict:
    """Same acquirable-items analysis as structured JSON (item_type,
    fort_walk_group, states{}, buckets[{reason, hint, units, by_z, top_tiles,
    top_materials}], carriers[{name, units}]). Read-only."""
    return fetch_acquirable(item_type or None)


@mcp.tool()
def diagnose_brewing() -> str:
    """Root-cause analysis for 'why isn't anyone making beer?'. Walks the
    brewing pipeline (order queued -> still built/free -> brewable plants on
    hand -> empty container to store the drink -> a dwarf able to brew) and
    returns a ranked list of likely blockers plus the underlying facts.
    Read-only; gathers facts only."""
    return _safe(format_brewing_diagnosis, fetch_brewing_diagnosis)


@mcp.tool()
def diagnose_brewing_data() -> dict:
    """Same brewing diagnosis as structured JSON (checks[] with ok/severity,
    plus facts{}). Read-only."""
    return fetch_brewing_diagnosis()


@mcp.tool()
def dwarf_roster() -> str:
    """One-line-per-dwarf roster of all fort citizens: name, profession, what
    they're doing now, stress band, unmet-need count, wounded flag, and any
    strange mood. Sorted with the busy/stressed dwarves first. Read-only."""
    return _safe(format_roster, fetch_roster)


@mcp.tool()
def dwarf_roster_data() -> dict:
    """Same citizen roster as structured JSON. Read-only."""
    return fetch_roster()


@mcp.tool()
def dwarf_detail(selector: str) -> str:
    """Deep profile of ONE citizen, selected by numeric unit id or a
    case-insensitive name substring: labors, top skills, current job (and if
    suspended), unmet needs, recent thoughts, stress/mood, and health timers.
    If the selector matches zero or several dwarves, returns the candidate list
    to choose from. Read-only."""
    try:
        return format_dwarf_detail(fetch_dwarf_detail(selector))
    except DFHackError as e:
        return f"Could not read fortress data: {e}"


@mcp.tool()
def dwarf_detail_data(selector: str) -> dict:
    """Same single-dwarf profile as structured JSON. Read-only."""
    return fetch_dwarf_detail(selector)


@mcp.tool()
def mood_report() -> str:
    """Fort-wide strange-mood status: every dwarf currently in a mood (Fey/
    Secretive/Possessed/Macabre/Fell, plus already-insane states), the workshop
    they claimed, and what their job still DEMANDS -- each requirement cross-
    referenced against on-hand stock so you see whether the material is available,
    owned-but-locked, or not-yet-acquired (e.g. silk that exists only as
    uncollected webs). Flags blocked requirements that lead to insanity if unmet.
    Read-only."""
    return _safe(format_mood, fetch_mood)


@mcp.tool()
def mood_report_data() -> dict:
    """Same strange-mood scan as structured JSON (moods[] with per-requirement
    needed/filled/available/satisfiable). Read-only."""
    return fetch_mood()


@mcp.tool()
def labor_coverage(labor: str = "BREWER") -> str:
    """Who can do a given labor and whether they're available. `labor` is a
    df.unit_labor name (e.g. BREWER, COOK, MASON, HAUL_FOOD); defaults to BREWER.
    Lists each citizen with the labor enabled (idle/busy + stress) plus any
    work details governing it. Read-only."""
    try:
        return format_labor_coverage(fetch_labor_coverage(labor))
    except DFHackError as e:
        return f"Could not read fortress data: {e}"


@mcp.tool()
def labor_coverage_data(labor: str = "BREWER") -> dict:
    """Same labor-coverage view as structured JSON. Read-only."""
    return fetch_labor_coverage(labor)


@mcp.tool()
def bedroom_assignments() -> str:
    """Every placed bed mapped to its assigned citizen. Shows unowned beds
    and citizens who have no bed assigned — the quickest way to spot who is
    sleeping on the floor. Read-only."""
    return _safe(format_bedroom_assignments, fetch_bedroom_assignments)


@mcp.tool()
def bedroom_assignments_data() -> dict:
    """Same bedroom assignment view as structured JSON (beds[], citizens_without_beds[],
    total_beds, unowned_beds, total_citizens). Read-only."""
    return fetch_bedroom_assignments()


@mcp.tool()
def announcements_report(limit: int = 50) -> str:
    """Recent game announcements and notifications (job cancellations, attacks,
    mood events, alerts). Returns the last `limit` entries (default 50).
    Read-only; does not change anything in the game."""
    try:
        return format_announcements(fetch_announcements(limit))
    except Exception as e:
        return f"Could not read announcements: {e}"


@mcp.tool()
def announcements_data(limit: int = 50) -> dict:
    """Same announcements as structured JSON (announcements[], total, shown).
    Read-only."""
    return fetch_announcements(limit)


@mcp.tool()
def artifact_locate(selector: str) -> str:
    """Find ONE artifact by name substring or numeric artifact id and report its
    item type, material, quality, maker, and CURRENT location (carried by a unit
    / stored inside a container / installed in a building / lying at x,y,z), or
    that it is lost. If the selector matches zero or several artifacts, returns
    the candidate list to choose from. Read-only."""
    try:
        return format_artifact(fetch_artifact(selector))
    except DFHackError as e:
        return f"Could not read fortress data: {e}"


@mcp.tool()
def artifact_locate_data(selector: str) -> dict:
    """Same artifact lookup as structured JSON (artifact{item_type, material,
    quality, maker, location{}}). Read-only."""
    return fetch_artifact(selector)


@mcp.tool()
def deity_detail(selector: str) -> str:
    """Look up ONE deity by name substring and report its spheres/domains and
    which fort temple(s), if any, are dedicated to it. If the selector matches
    zero or several deities, returns the candidate list to choose from.
    Read-only."""
    try:
        return format_deity(fetch_deity(selector))
    except DFHackError as e:
        return f"Could not read fortress data: {e}"


@mcp.tool()
def deity_detail_data(selector: str) -> dict:
    """Same deity lookup as structured JSON (deity{spheres[], temples[]}).
    Read-only."""
    return fetch_deity(selector)


@mcp.tool()
def citizen_faith(selector: str) -> str:
    """Report ONE citizen's religion: the deity/deities they worship (with
    worship strength and spheres) and which fort temple serves each -- i.e. the
    fitting place to display an artifact that dwarf made in a mood. Selector is a
    numeric unit id or a name substring; zero/several matches return the candidate
    list. Read-only."""
    try:
        return format_faith(fetch_faith(selector))
    except DFHackError as e:
        return f"Could not read fortress data: {e}"


@mcp.tool()
def citizen_faith_data(selector: str) -> dict:
    """Same citizen-faith lookup as structured JSON (dwarf{deities[] with
    strength, spheres, temples}). Read-only."""
    return fetch_faith(selector)


@mcp.tool()
def hotkeys_report() -> str:
    """Plain-text table of all 16 F-key map bookmarks for the loaded fort:
    key label (F1-F16), bookmark name, and map coordinates. Inactive slots
    are shown as (unset). Read-only; does not change anything in the game."""
    return _safe(format_hotkeys_report, fetch_hotkeys_intel)


@mcp.tool()
def hotkeys_data() -> dict:
    """Same F-key map bookmark listing as structured JSON (hotkeys[] with key,
    name, x, y, z, active). Read-only."""
    return fetch_hotkeys_intel()


@mcp.tool()
def caravan_report() -> str:
    """Active caravan status for the loaded fort: entity name and civ, trade
    state (approaching / at depot / leaving), items requested by the trade
    agreement, and a count of trader-flagged goods at the depot by item type.
    Read-only."""
    return _safe(format_caravan_report, fetch_caravan_intel)


@mcp.tool()
def caravan_data() -> dict:
    """Same active caravan status as structured JSON (caravans[], caravan_count,
    cur_year, cur_year_tick, trade_goods_by_type, trade_goods_count). Read-only."""
    return fetch_caravan_intel()


@mcp.tool()
def trade_history_report(limit: int = 100) -> str:
    """Persistent log of past caravan arrivals written by the DFHack hook.
    Shows entity name, trade state, year/tick, and requested items for the most
    recent `limit` arrivals (default 100). Reads a local JSON file — no live
    game connection needed. Returns a setup message if the hook is not yet
    installed."""
    try:
        return format_trade_history_report(fetch_trade_history(limit))
    except Exception as e:
        return f"Could not read trade history: {e}"


@mcp.tool()
def trade_history_data(limit: int = 100) -> dict:
    """Same persistent caravan history as structured JSON (records[], total,
    shown, path_exists). Reads agent/data/trade_history.json — no live game
    connection needed."""
    try:
        return fetch_trade_history(limit)
    except Exception as e:
        return {"records": [], "total": 0, "shown": 0,
                "path_exists": False, "error": str(e)}


@mcp.tool()
def agreements_report() -> str:
    """Diplomatic agreements and entity relations for the loaded fort. Reads
    world.diplomacy (entity anger, relation flags) and attempts world.agreements
    if accessible on this DFHack version. Always includes a probe section
    reporting which struct paths succeeded. Read-only."""
    return _safe(format_agreements_report, fetch_agreements_intel)


@mcp.tool()
def agreements_data() -> dict:
    """Same diplomatic data as structured JSON (diplomacy_entities[], agreements[],
    probe{}). Read-only."""
    return fetch_agreements_intel()


# --- WRITE ("act") tools ----------------------------------------------------
# These are the ONLY tools that can change game state, and only in mode='apply'
# with confirm=True. Default mode='advise' and mode='preview' are read-only.

@mcp.tool()
def queue_work_order(job: str, amount: int = 10, material: str = "any",
                     frequency: str = "one-time", mode: str = "advise",
                     confirm: bool = False) -> str:
    """Create a single manager work order. `job` is a df.job_type name
    (e.g. 'MakeCrafts', 'BrewDrink', 'WeaveCloth'); `material` is a class like
    stone/wood/cloth or 'any'; `frequency` is one-time/daily/monthly/seasonal/
    yearly. mode='advise' (default) explains it + manual steps; mode='preview'
    shows the exact order; mode='apply' with confirm=true WRITES it (reversible:
    cancel in-game). WRITES ONLY in apply+confirm."""
    return _safe2(_queue_work_order, job, amount, material, frequency, mode,
                  confirm)


@mcp.tool()
def auto_stock_target(item: str, target: int, job: str = "", material: str = "any",
                      frequency: str = "daily", mode: str = "advise",
                      confirm: bool = False) -> str:
    """Keep at least `target` of an item on hand via a conditional repeat order
    ('when AMOUNT < target'). `item` is a df.item_type name (e.g. 'DRINK'); for
    items other than DRINK pass the producing `job`. mode advise/preview are
    read-only; mode='apply' with confirm=true WRITES the standing order."""
    return _safe2(_auto_stock_target, item, target, job or None, material,
                  frequency, mode, confirm)


@mcp.tool()
def fix_idle(mode: str = "advise", confirm: bool = False) -> str:
    """Put idle dwarves to work: matches idle workshops + surplus materials and
    queues stone-craft / mechanism / weaving orders. mode='advise' (default) and
    mode='preview' are read-only; mode='apply' with confirm=true WRITES the
    orders (reversible)."""
    return _safe2(_fix_idle, mode, confirm)


@mcp.tool()
def manage_containers(mode: str = "advise", confirm: bool = False) -> str:
    """Relieve a storage-container crunch by queuing rock-pot / wooden-bin
    production when none are empty. Stockpile re-assignment is advice-only.
    mode advise/preview are read-only; mode='apply' with confirm=true WRITES the
    production orders (reversible)."""
    return _safe2(_manage_containers, mode, confirm)


@mcp.tool()
def boost_mood(mode: str = "advise", confirm: bool = False) -> str:
    """Raise fort mood: tops up alcohol with a reversible brew order and advises
    the big zone-based wins (tavern/temple/library), which it does NOT write.
    mode advise/preview are read-only; mode='apply' with confirm=true WRITES the
    brew order only."""
    return _safe2(_boost_mood, mode, confirm)


@mcp.tool()
def manage_hospital_supplies(supplies: dict, hospital: str = "",
                             mode: str = "advise", confirm: bool = False) -> str:
    """Set an EXISTING hospital's desired-supply maximums (reversible). `supplies`
    maps any of splints/thread/cloth/crutches/powder/buckets/soap to a
    non-negative integer maximum in WHOLE ITEMS, exactly as shown on the in-game
    hospital screen (e.g. {"cloth": 5, "splints": 5} -> the screen's <5>); DF's
    internal dimension units are handled for you. `hospital`
    selects by name substring when more than one exists. mode='advise' (default)
    and mode='preview' are read-only; mode='apply' with confirm=true WRITES the
    new maximums (reversible: set the field back to its old value). Does NOT
    create/delete/resize/designate zones -- zone creation stays advice-only."""
    return _safe2(_set_hospital_supplies, supplies, hospital, mode, confirm)


@mcp.tool()
def set_hotkey(key_id: int, name: str, x: int = 0, y: int = 0, z: int = 0,
               mode: str = "advise", confirm: bool = False) -> str:
    """Set or clear an F-key map bookmark (F1-F16). `key_id` is 1-16; `name`
    is the bookmark label; `x`/`y`/`z` are the map coordinates to jump to.
    Pass name='' to clear the slot. mode='advise' (default) explains it + manual
    steps; mode='preview' shows the old->new diff; mode='apply' with confirm=true
    WRITES the bookmark (reversible: call again with the old values to restore).
    WRITES ONLY in apply+confirm."""
    return _safe2(_set_hotkey, key_id, name, x, y, z, mode, confirm)


def _safe2(fn, *args):
    """Like _safe, but for the act tools which take args and return text."""
    try:
        return fn(*args)
    except DFHackError as e:
        return f"Could not reach fortress: {e}"


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        # Exercise every tool without an MCP client.
        for name, fn in (
            ("fort_briefing", fort_briefing),
            ("brewing_report", brewing_report),
            ("cooking_report", cooking_report),
            ("diagnose_cooking", diagnose_cooking),
            ("farming_report", farming_report),
            ("diagnose_farming", diagnose_farming),
            ("fishing_report", fishing_report),
            ("diagnose_fishing", diagnose_fishing),
            ("butchery_report", butchery_report),
            ("diagnose_butchery", diagnose_butchery),
            ("textiles_report", textiles_report),
            ("diagnose_textiles", diagnose_textiles),
            ("metal_report", metal_report),
            ("diagnose_metal", diagnose_metal),
            ("fuel_report", fuel_report),
            ("diagnose_fuel", diagnose_fuel),
            ("construction_report", construction_report),
            ("diagnose_construction", diagnose_construction),
            ("medical_report", medical_report),
            ("diagnose_medical", diagnose_medical),
            ("justice_report", justice_report),
            ("diagnose_justice", diagnose_justice),
            ("zones_report", zones_report),
            ("hotkeys_report", hotkeys_report),
            ("stock_report", stock_report),
            ("stock_report(TOOL)", lambda: stock_report("TOOL")),
            ("container_report", container_report),
            ("shops_and_orders_report", shops_and_orders_report),
            ("stockpile_locate('nest box')",
             lambda: stockpile_locate("nest box")),
            ("building_locate('lever')", lambda: building_locate("lever")),
            ("stockpile_config", stockpile_config),
            ("building_config", building_config),
            ("item_detail(first wheelbarrow)", lambda: item_detail(
                (fetch_stockpile_locate("wheelbarrow").get("items")
                 or [{}])[0].get("id", 0))),
            ("diagnose_brewing", diagnose_brewing),
            ("dwarf_roster", dwarf_roster),
            ("mood_report", mood_report),
            ("labor_coverage(BREWER)", lambda: labor_coverage("BREWER")),
            ("artifact_locate('')", lambda: artifact_locate("")),
            ("deity_detail('')", lambda: deity_detail("")),
            ("citizen_faith('')", lambda: citizen_faith("")),
            ("caravan_report", caravan_report),
            ("trade_history_report", trade_history_report),
            ("agreements_report", agreements_report),
        ):
            print(f"\n########## {name} ##########")
            print(fn())
    else:
        mcp.run()  # stdio transport
