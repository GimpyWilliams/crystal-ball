"""
Zones & locations for crystal-ball (READ-ONLY).

`fetch_zones_intel` / `format_zones_report` surface the fort's LOCATIONS
(taverns, temples, hospitals, libraries, guildhalls -- abstract buildings on the
fort site) and a by-type count of raw civzones. In DF50 a hospital is a location,
not a civzone (see scripts/zones_intel.lua and the fort_locations() helper in
scripts/_prelude.lua).

The reversible hospital-supply WRITE that pairs with this view lives in
mutations.py (set_hospital_supplies), next to the other "act" tools; it validates
against HOSPITAL_SUPPLY_FIELDS below.
"""

from intel import run_intel
from intel import as_map
from reports import append_errors

# The hospital supply knobs we expose for reading and (reversible) writing -- the
# contents.desired_<field> maximums on an abstract_building_hospitalst. Surfaced
# in WHOLE ITEMS (as the in-game hospital screen shows them): zones_intel.lua and
# set_hospital_supplies.lua convert to/from DF's internal "dimension" units, so
# thread/cloth/powder/soap aren't reported in their raw 1000s.
HOSPITAL_SUPPLY_FIELDS = (
    "splints", "thread", "cloth", "crutches", "powder", "buckets", "soap",
)


def fetch_zones_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("zones_intel.lua", host=host, port=port)


def format_zones_report(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    lines = ["=== Zones & Locations ==="]

    locations = data.get("locations") or []
    lines.append(f"\nLocations on this site: {len(locations)}")
    for loc in locations:
        loc = as_map(loc)
        lines.append(f"  - {loc.get('type', '?')}: {loc.get('name', '?')}")
        hosp = as_map(loc.get("hospital"))
        for key in ("splints", "thread", "cloth", "crutches", "powder",
                    "buckets", "soap"):
            s = as_map(hosp.get(key))
            if s:
                lines.append(f"      {key}: {s.get('have', 0)}/{s.get('max', 0)} "
                             "(stocked/max)")

    cz = as_map(data.get("civzones"))
    lines.append(f"\nCivzones (raw zone rectangles): {cz.get('total', 0)} total")
    by_type = as_map(cz.get("by_type"))
    for tname, n in sorted(by_type.items(), key=lambda kv: -kv[1]):
        lines.append(f"  {n:>3}  {tname}")

    append_errors(lines, data)
    return "\n".join(lines)
