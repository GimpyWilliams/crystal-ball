"""
READ-ONLY intel for the metal industry (ore -> bars -> goods) and the fuel
industry (wood -> charcoal; coal -> coke) that feeds it. Each function runs one
bundled, audited Lua query through DFHack's RunCommand RPC and formats the
result. Nothing here changes game state.
"""

from intel import as_map, run_intel
from reports import append_errors, format_diagnosis


# --- metal: intel report ---------------------------------------------------

def fetch_metal_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("metal_intel.lua", host=host, port=port)


def format_metal_report(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    lines = ["=== Metal Industry Report ==="]

    ore = as_map(data.get("ore"))
    lines.append(f"\nMetal ore: {ore.get('free_units', 0)} free / "
                 f"{ore.get('total_units', 0)} total")
    for mat, n in sorted(as_map(ore.get("by_material")).items(),
                         key=lambda kv: -kv[1]):
        lines.append(f"  {n:>5}  {mat}")
    if not as_map(ore.get("by_material")):
        lines.append("  (no metal ore on hand)")

    bars = as_map(data.get("bars"))
    lines.append(f"\nMetal bars: {bars.get('metal_free', 0)} free   "
                 f"(fuel on hand: {bars.get('fuel_units', 0)})")
    for mat, n in sorted(as_map(bars.get("metal_by_material")).items(),
                         key=lambda kv: -kv[1]):
        lines.append(f"  {n:>5}  {mat}")

    sm = as_map(data.get("smelters"))
    fo = as_map(data.get("forges"))
    lines.append(f"\nSmelters: {sm.get('count', 0)} ({sm.get('busy', 0)} busy, "
                 f"{sm.get('magma', 0)} magma)   "
                 f"Forges: {fo.get('count', 0)} ({fo.get('busy', 0)} busy, "
                 f"{fo.get('magma', 0)} magma)")

    orders = as_map(data.get("orders"))
    lines.append(f"\nOrders: {orders.get('smelt_left', 0)} to smelt, "
                 f"{orders.get('forge_left', 0)} to forge")

    append_errors(lines, data)
    return "\n".join(lines)


# --- metal: diagnosis ------------------------------------------------------

def fetch_metal_diagnosis(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("diagnose_metal.lua", host=host, port=port)


_METAL_LABELS = {
    "smelter_exists": "Smelter built",
    "ore_available": "Metal ore on hand",
    "fuel_for_smelting": "Fuel (or magma) for smelting",
    "smelter_labor": "A dwarf can/does smelt",
    "forge_exists": "Forge built",
    "forge_labor": "A dwarf can/does forge",
}


def format_metal_diagnosis(data: dict) -> str:
    return format_diagnosis(
        data, "=== Why isn't metal being made? ===", _METAL_LABELS,
        ("smelters", "magma_smelters", "ore_free", "fuel_units", "forges"),
        "if smelting is still stalled the cause is likely subtler (ore is not "
        "flagged for smelting, unreachable items, or a burrow/stockpile "
        "restriction)")


# --- fuel: intel report ----------------------------------------------------

def fetch_fuel_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("fuel_intel.lua", host=host, port=port)


def format_fuel_report(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    lines = ["=== Fuel Report ==="]

    fuel = as_map(data.get("fuel"))
    lines.append(f"\nFuel (charcoal/coke): {fuel.get('free_units', 0)} free / "
                 f"{fuel.get('total_units', 0)} total")
    for mat, n in sorted(as_map(fuel.get("by_material")).items(),
                         key=lambda kv: -kv[1]):
        lines.append(f"  {n:>5}  {mat}")

    wood = as_map(data.get("wood"))
    lines.append(f"\nLogs: {wood.get('free_units', 0)} free / "
                 f"{wood.get('total_units', 0)} total")

    wf = as_map(data.get("wood_furnaces"))
    magma = as_map(data.get("magma"))
    lines.append(f"\nWood furnaces: {wf.get('count', 0)} ({wf.get('busy', 0)} busy)"
                 f"   Magma smelters/forges: {magma.get('smelters', 0)}/"
                 f"{magma.get('forges', 0)} (need no charcoal)")

    left = data.get("charcoal_orders_left", 0)
    lines.append(f"\nCharcoal orders: {left} to make")

    append_errors(lines, data)
    return "\n".join(lines)


# --- fuel: diagnosis -------------------------------------------------------

def fetch_fuel_diagnosis(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("diagnose_fuel.lua", host=host, port=port)


_FUEL_LABELS = {
    "woodfurnace_exists": "Wood furnace built",
    "wood_available": "Logs on hand",
    "burner_assigned": "A dwarf can/does burn wood",
    "magma_alternative": "No magma alternative in use",
}


def format_fuel_diagnosis(data: dict) -> str:
    return format_diagnosis(
        data, "=== Why isn't charcoal being made? ===", _FUEL_LABELS,
        ("wood_furnaces", "logs_free", "magma_buildings"),
        "if charcoal is still not being made the cause is likely subtler (no "
        "MakeCharcoal order queued, or you rely on magma and don't need it)")
