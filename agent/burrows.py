"""
Burrow intel for crystal-ball (READ-ONLY).

`fetch_burrows_intel` / `format_burrows_report` list the fort's burrows (id, name,
size, how many units are assigned) and the citizens who belong to each, with the
syndrome classes each citizen carries so a group (e.g. every NECROMANCER) can be
selected at once.

The reversible burrow-assignment WRITE that pairs with this view lives in
mutations.py (assign_burrow_units MCP tool).
"""

from intel import run_intel, as_map
from reports import append_errors


def fetch_burrows_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("burrows_intel.lua", host=host, port=port)


def format_burrows_report(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    burrows = data.get("burrows") or []
    citizens = data.get("citizens") or []
    lines = [f"=== Burrows — {len(burrows)} defined, {len(citizens)} citizens ==="]

    if not burrows:
        lines.append("  (no burrows exist -- create one in-game first, then "
                     "assign units to it)")
    for b in burrows:
        b = as_map(b)
        name = b.get("name") or "(unnamed)"
        lines.append(f"  #{b.get('id')}  {name}  — {b.get('units', 0)} unit(s) "
                     f"assigned, {b.get('blocks', 0)} map block(s)")

    # Syndrome-class groups make "select every necromancer" a one-liner.
    groups: dict[str, int] = {}
    for c in citizens:
        for cls in as_map(c).get("syn_classes") or []:
            groups[cls] = groups.get(cls, 0) + 1
    if groups:
        lines.append("\nCitizens by syndrome class (usable as syndrome_class):")
        for cls, n in sorted(groups.items(), key=lambda kv: -kv[1]):
            lines.append(f"  {cls}: {n}")

    append_errors(lines, data)
    return "\n".join(lines)
