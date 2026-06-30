"""
READ-ONLY intel for the food-cluster industries (cooking first; farming,
butchery, and fishing to follow). Each function runs one bundled, audited Lua
query (scripts/*.lua) through DFHack's RunCommand RPC and formats the result.
Nothing here changes game state, and no command string is ever taken from a
caller -- the only thing ever executed is one of the fixed script files.
"""

from intel import as_map, run_intel
from reports import append_errors as _append_errors
from reports import format_diagnosis as _format_diagnosis

# --- cooking: intel report -------------------------------------------------

def fetch_cooking_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("cooking_intel.lua", host=host, port=port)


def format_cooking_report(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    lines = ["=== Cooking / Kitchen Report ==="]

    meals = as_map(data.get("meals"))
    lines.append(f"\nPrepared meals on hand: {meals.get('total_units', 0)} units")

    ing = as_map(data.get("ingredients"))
    lines.append(f"\nCookable ingredients: {ing.get('free_units', 0)} free / "
                 f"{ing.get('total_units', 0)} total units, "
                 f"{ing.get('distinct_free_types', 0)} distinct type(s) free")
    by_type = as_map(ing.get("by_type"))
    for tname, c in sorted(by_type.items(), key=lambda kv: -kv[1].get("free", 0)):
        lines.append(f"  {c.get('free', 0):>5} free / {c.get('units', 0):>5}  "
                     f"{tname}")
    if not by_type:
        lines.append("  (no cookable ingredients on hand)")
    if ing.get("distinct_free_types", 0) < 2:
        lines.append("  WARNING: a meal needs >= 2 distinct ingredients; "
                     "cooking will stall on variety.")

    kit = as_map(data.get("kitchens"))
    lines.append(f"\nKitchens: {kit.get('count', 0)} "
                 f"({kit.get('busy', 0)} currently working)")

    orders = data.get("cook_orders") or []
    if orders:
        total_left = sum(o.get("amount_left", 0) for o in orders)
        lines.append(f"\nCook work orders: {len(orders)} "
                     f"({total_left} meals still to make)")
    else:
        lines.append("\nCook work orders: none")

    _append_errors(lines, data)
    return "\n".join(lines)


# --- cooking: diagnosis ----------------------------------------------------

def fetch_cooking_diagnosis(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("diagnose_cooking.lua", host=host, port=port)


_COOKING_LABELS = {
    "cook_order_exists": "Cook order queued",
    "kitchen_exists": "Kitchen built",
    "cook_job_running": "Cook job at a kitchen",
    "ingredients_available": "Cookable ingredients on hand",
    "ingredient_variety": ">= 2 distinct ingredients",
    "cook_assigned": "A dwarf can/does cook",
}


def format_cooking_diagnosis(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."

    checks = data.get("checks") or []
    facts = as_map(data.get("facts"))

    blockers = [c for c in checks if c.get("severity") == "blocker"
                and c.get("ok") is False]
    unknown = [c for c in checks if c.get("ok") is None]

    lines = ["=== Why aren't meals being cooked? ==="]

    if blockers:
        lines.append(f"\nLikely blockers ({len(blockers)}):")
        for c in blockers:
            lines.append(f"  [X] {_cook_label(c['name'])}: {c.get('detail', '')}")
    else:
        lines.append("\nNo hard blocker found along the cooking pipeline. Every "
                     "prerequisite below is satisfied, so if cooking is still "
                     "stalled the cause is likely subtler (ingredients flagged "
                     "'do not cook' in kitchen settings, unreachable items, a "
                     "burrow/stockpile restriction, idle cooks busy elsewhere, "
                     "or the order's conditions not yet met).")

    if unknown:
        lines.append("\nCould not evaluate (check manually):")
        for c in unknown:
            lines.append(f"  [?] {_cook_label(c['name'])}: {c.get('detail', '')}")

    lines.append("\nPipeline checklist:")
    for c in checks:
        mark = {True: "ok ", False: "XX ", None: "?? "}[c.get("ok")]
        lines.append(f"  {mark}{_cook_label(c['name'])}: {c.get('detail', '')}")

    lines.append("\nFacts:")
    for k in ("cook_order_units_left", "kitchens", "kitchens_idle",
              "active_cook_jobs", "ingredient_units_free",
              "distinct_ingredient_types", "cook_work_details",
              "cook_work_detail_units"):
        if k in facts:
            lines.append(f"  {k} = {facts[k]}")

    _append_errors(lines, data, "some checks could not be read")
    return "\n".join(lines)


def _cook_label(name: str) -> str:
    return _COOKING_LABELS.get(name, name)


# --- farming: intel report -------------------------------------------------

def fetch_farming_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("farming_intel.lua", host=host, port=port)


def format_farming_report(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    season = as_map(data.get("season"))
    lines = [f"=== Farming Report ({season.get('name', '?')}) ==="]

    plots = as_map(data.get("plots"))
    lines.append(f"\nFarm plots: {plots.get('count', 0)} "
                 f"({plots.get('total_tiles', 0)} tiles); "
                 f"{plots.get('plots_with_crop_this_season', 0)} planted this "
                 f"season ({plots.get('tiles_assigned_this_season', 0)} tiles)")
    lines.append(f"  active jobs: {plots.get('active_plant_jobs', 0)} planting, "
                 f"{plots.get('active_harvest_jobs', 0)} harvesting")

    this_season = as_map(plots.get("this_season"))
    if this_season:
        lines.append("\nAssigned this season (crop: tiles, seeds):")
        for crop, c in sorted(this_season.items(),
                              key=lambda kv: -kv[1].get("tiles", 0)):
            sf = c.get("seeds_free", 0)
            warn = "  <-- NO SEEDS" if sf == 0 else ""
            lines.append(f"  {crop}: {c.get('tiles', 0)} tiles, "
                         f"{sf} seed(s){warn}")
    else:
        lines.append("\nNothing assigned to plant this season.")

    seeds = as_map(data.get("seeds"))
    lines.append(f"\nSeeds: {seeds.get('free_units', 0)} available / "
                 f"{seeds.get('total_units', 0)} on hand")
    by_crop = as_map(seeds.get("by_crop"))
    for crop, c in sorted(by_crop.items(), key=lambda kv: -kv[1].get("free", 0)):
        lines.append(f"  {c.get('free', 0):>4} available / "
                     f"{c.get('total', 0):>4} on hand  {crop}")
    if not by_crop:
        lines.append("  (no seeds -- planting will stall)")

    _append_errors(lines, data)
    return "\n".join(lines)


# --- farming: diagnosis ----------------------------------------------------

def fetch_farming_diagnosis(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("diagnose_farming.lua", host=host, port=port)


_FARMING_LABELS = {
    "farm_plot_exists": "Farm plot built",
    "crop_assigned": "Crop set for this season",
    "seeds_available": "Seeds for the assigned crop(s)",
    "planter_assigned": "A dwarf can/does farm",
    "planting_active": "Planting job at a plot",
}


def format_farming_diagnosis(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."

    checks = data.get("checks") or []
    facts = as_map(data.get("facts"))

    blockers = [c for c in checks if c.get("severity") == "blocker"
                and c.get("ok") is False]
    unknown = [c for c in checks if c.get("ok") is None]

    lines = ["=== Why aren't crops being planted? ==="]

    if blockers:
        lines.append(f"\nLikely blockers ({len(blockers)}):")
        for c in blockers:
            lines.append(f"  [X] {_farm_label(c['name'])}: {c.get('detail', '')}")
    else:
        lines.append("\nNo hard blocker found along the farming pipeline. Every "
                     "prerequisite below is satisfied, so if planting is still "
                     "stalled the cause is likely subtler (plots indoors vs the "
                     "crop needing sun, a burrow/stockpile restriction, idle "
                     "farmers busy elsewhere, or it is simply between planting "
                     "cycles).")

    if unknown:
        lines.append("\nCould not evaluate (check manually):")
        for c in unknown:
            lines.append(f"  [?] {_farm_label(c['name'])}: {c.get('detail', '')}")

    lines.append("\nPipeline checklist:")
    for c in checks:
        mark = {True: "ok ", False: "XX ", None: "?? "}[c.get("ok")]
        lines.append(f"  {mark}{_farm_label(c['name'])}: {c.get('detail', '')}")

    lines.append("\nFacts:")
    for k in ("season", "farm_plots", "plots_with_crop_this_season",
              "assigned_crops", "assigned_crops_with_seed", "active_plant_jobs",
              "farm_work_details", "farm_work_detail_units"):
        if k in facts:
            lines.append(f"  {k} = {facts[k]}")

    _append_errors(lines, data, "some checks could not be read")
    return "\n".join(lines)


def _farm_label(name: str) -> str:
    return _FARMING_LABELS.get(name, name)


# --- fishing: intel report -------------------------------------------------

def fetch_fishing_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("fishing_intel.lua", host=host, port=port)


def format_fishing_report(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    lines = ["=== Fishing Report ==="]

    fish = as_map(data.get("fish"))
    lines.append(f"\nEdible fish on hand: {fish.get('total_units', 0)} units")
    for mat, n in sorted(as_map(fish.get("by_material")).items(),
                         key=lambda kv: -kv[1]):
        lines.append(f"  {n:>5}  {mat}")

    raw = as_map(data.get("raw_fish"))
    lines.append(f"\nRaw fish waiting to clean: {raw.get('free_units', 0)} free / "
                 f"{raw.get('total_units', 0)} total")

    fi = as_map(data.get("fisheries"))
    lines.append(f"\nFisheries: {fi.get('count', 0)} "
                 f"({fi.get('busy', 0)} currently working)")

    orders = data.get("clean_orders") or []
    if orders:
        total_left = sum(o.get("amount_left", 0) for o in orders)
        lines.append(f"\nClean-fish work orders: {len(orders)} "
                     f"({total_left} still to clean)")
    else:
        lines.append("\nClean-fish work orders: none")

    _append_errors(lines, data)
    return "\n".join(lines)


# --- fishing: diagnosis ----------------------------------------------------

def fetch_fishing_diagnosis(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("diagnose_fishing.lua", host=host, port=port)


_FISHING_LABELS = {
    "fishery_exists": "Fishery built",
    "raw_fish_processing": "Raw fish being cleaned",
    "fisher_assigned": "A dwarf can/does catch fish",
    "cleaner_assigned": "A dwarf can/does clean fish",
    "fishable_water": "Fishable water available",
}


def format_fishing_diagnosis(data: dict) -> str:
    return _format_diagnosis(
        data, "=== Why isn't fish food being produced? ===", _FISHING_LABELS,
        ("edible_fish", "raw_fish_free", "fisheries", "fisheries_idle",
         "active_clean_jobs"),
        "if fishing is still stalled the cause is likely subtler (no fishing "
        "zone over water, the water has no fish population, or a "
        "burrow/stockpile restriction)")


# --- butchery + tanning: intel report --------------------------------------

def fetch_butchery_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("butchery_intel.lua", host=host, port=port)


def format_butchery_report(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    lines = ["=== Butchery / Tanning Report ==="]

    lines.append(f"\nAnimals marked for slaughter: "
                 f"{data.get('marked_for_slaughter', 0)}")
    lines.append(f"Butcherable corpses present: {data.get('corpses', 0)}")

    shops = as_map(data.get("butcher_shops"))
    lines.append(f"\nButcher's shops: {shops.get('count', 0)} "
                 f"({shops.get('busy', 0)} currently working)")

    out = as_map(data.get("output"))
    lines.append(f"\nOutput on hand: {out.get('meat', 0)} meat, "
                 f"{out.get('fat', 0)} fat")

    tan = as_map(data.get("tanning"))
    tanneries = as_map(tan.get("tanneries"))
    lines.append(f"\nTanning: {tanneries.get('count', 0)} tannery(ies) "
                 f"({tanneries.get('busy', 0)} working), "
                 f"{tan.get('leather_units', 0)} leather on hand")

    orders = data.get("butcher_orders") or []
    if orders:
        total_left = sum(o.get("amount_left", 0) for o in orders)
        lines.append(f"\nButcher work orders: {len(orders)} "
                     f"({total_left} still to butcher)")

    _append_errors(lines, data)
    return "\n".join(lines)


# --- butchery: diagnosis ---------------------------------------------------

def fetch_butchery_diagnosis(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("diagnose_butchery.lua", host=host, port=port)


_BUTCHERY_LABELS = {
    "butcher_shop_exists": "Butcher's shop built",
    "something_to_butcher": "Animals/corpses to butcher",
    "butcher_assigned": "A dwarf can/does butcher",
    "tannery_exists": "Tanner's shop built",
    "tanner_assigned": "A dwarf can/does tan",
}


def format_butchery_diagnosis(data: dict) -> str:
    return _format_diagnosis(
        data, "=== Why isn't anything being butchered? ===", _BUTCHERY_LABELS,
        ("marked_for_slaughter", "corpses", "butcher_shops", "active_butcher_jobs",
         "leather_units", "tanneries"),
        "if butchering is still stalled the cause is likely subtler (the animal "
        "is a pet/sentient and can't be slaughtered, no refuse stockpile for the "
        "byproducts, or a burrow/stockpile restriction)")


# Shared formatters (_format_diagnosis, _append_errors) now live in reports.py.
