"""
Beer-production intelligence for a live Dwarf Fortress + DFHack instance.

READ-ONLY. This module runs a single vetted Lua query (scripts/brewing_intel.lua)
through DFHack's RunCommand RPC and formats the result. It never issues a
state-changing command and never accepts a command string from the caller --
the only thing it ever runs is the bundled, audited script file.
"""

from intel import as_map as _as_map
from intel import run_intel


def fetch_brewing_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    """Connect to local DFHack, run the read-only query, return parsed data."""
    return run_intel("brewing_intel.lua", host=host, port=port)


def format_report(data: dict) -> str:
    """Render the intel dict as a plain-text report suitable for a terminal."""
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    lines: list[str] = ["=== Beer Production Report ==="]

    drinks = data.get("drinks", {})
    drink_mats = _as_map(drinks.get("by_material"))
    lines.append(f"\nDrinks on hand: {drinks.get('total_units', 0)} units")
    for mat, n in sorted(drink_mats.items(), key=lambda kv: -kv[1]):
        lines.append(f"  {n:>5}  {mat}")
    if not drink_mats:
        lines.append("  (none -- nothing brewed yet)")

    cont = data.get("empty_containers", {})
    barrels = cont.get("barrels", 0)
    pots = cont.get("large_pots", 0)
    lines.append(f"\nEmpty containers for new drinks: "
                 f"{barrels + pots}  ({barrels} barrels, {pots} large pots)")
    if barrels + pots == 0:
        lines.append("  WARNING: no empty containers -- brewing will stall.")

    stills = data.get("stills", {})
    lines.append(f"\nStills: {stills.get('count', 0)} "
                 f"({stills.get('busy', 0)} currently working)")

    orders = data.get("brew_orders", [])
    if orders:
        total_left = sum(o.get("amount_left", 0) for o in orders)
        lines.append(f"\nBrew work orders: {len(orders)} "
                     f"({total_left} drinks still to make)")
    else:
        lines.append("\nBrew work orders: none")

    plants = data.get("plants", {})
    lines.append(f"\nBrewable raw plants on hand: "
                 f"{plants.get('total_units', 0)} units")
    for mat, n in sorted(_as_map(plants.get("by_material")).items(),
                         key=lambda kv: -kv[1]):
        lines.append(f"  {n:>5}  {mat}")

    errs = data.get("errors", [])
    if errs:
        lines.append("\nNote -- some sections could not be read:")
        for e in errs:
            lines.append(f"  - {e}")

    return "\n".join(lines)
