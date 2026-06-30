"""
Command-line entry point for the read-only Dwarf Fortress intel reports.

Usage:
    python cli.py [report] [--json]

Reports:
    briefing    batched morning roll-up (moods/hospital/shops/stocks/blockers)
    brewing     beer-production status (default)
    stock [q]   stock inventory; optional focus ("DRINK", "TOOL", "nest box")
    containers  barrel/pot/bin/box storage audit
    locate <q>  where items are (free text: "nest box", "jug", THREAD, DRINK)
    building <q> where buildings are (free text: "lever", "smelter", "well")
    item <id>   deep inspection of one item by numeric id
    stockpile-config  per-stockpile accept categories + links + caps
    building-config   zone/room assignments (who owns which room)
    shops       workshops + manager order queue
    diagnose    root-cause: why isn't beer being made?
    livestock   tame animal census (sex/traits/breeding status)
    livestock-diag  breeding blockers (pen, nest box, missing mates)
    roster      one-line-per-dwarf citizen roster
    mood        strange-mood status: who's moody + what their job demands
    zones       zones & locations (taverns/temples/hospital/library) + civzones
    hotkeys     all 16 F-key map bookmarks (name + coordinates)
    dwarf <sel> deep profile of one dwarf (id or name substring)
    labor <nm>  who can do a labor (df.unit_labor name; default BREW)
    artifact <sel>  locate one artifact (id or name) + its current location
    deity <name>    a deity's spheres + which fort temple is dedicated to it
    faith <sel>     a dwarf's worshipped deity/deities + the temple to honor it

Act subcommands (default = advise; writes need both --apply and --confirm):
    queue-order <job> <amount> [material]   create one manager order
    stock-target <item> <target> [job]      keep >= target of item on hand
    fix-idle                                put idle dwarves to work
    containers-fix                          queue pots/bins when storage is full
    boost-mood                              top up alcohol + mood advice
    hospital-supplies <field> <max> ...     set hospital supply maximum(s)
    set-hotkey <key_id> <name> <x> <y> <z> set/clear an F-key map bookmark
  Flags: --preview (exact plan, no write), --apply --confirm (write).

Examples:
    python cli.py                 # brewing report (human-readable)
    python cli.py stock           # stock inventory
    python cli.py diagnose --json # diagnosis as raw JSON
    python cli.py dwarf Urist      # profile dwarves matching "Urist"
    python cli.py labor COOK       # who can cook
    python cli.py fix-idle         # advise: what idle-work it would queue
    python cli.py fix-idle --preview            # exact orders, no write
    python cli.py queue-order MakeCrafts 20 stone --apply --confirm
"""

import sys

# DF text isn't always valid UTF-8 / cp1252; keep the Windows console from
# crashing on the odd special-glyph dwarf name.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

from brewery import fetch_brewing_intel, format_report
from briefing import fetch_briefing, format_briefing
from diagnostics import fetch_brewing_diagnosis, format_brewing_diagnosis
from dwarves import (
    fetch_dwarf_detail,
    fetch_labor_coverage,
    fetch_roster,
    format_dwarf_detail,
    format_labor_coverage,
    format_roster,
)
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
from textiles import (
    fetch_textiles_diagnosis,
    fetch_textiles_intel,
    format_textiles_diagnosis,
    format_textiles_report,
)
from livestock import (
    fetch_livestock_diagnosis,
    fetch_livestock_intel,
    format_livestock_diagnosis,
    format_livestock_report,
)
from announcements import fetch_announcements, format_announcements
from mood import fetch_mood, format_mood
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
from mutations import (
    auto_stock_target,
    boost_mood,
    fix_idle,
    manage_containers,
    queue_work_order,
    set_hospital_supplies,
    set_hotkey,
)
from dfhack_rpc.client import DFHackError

# Each fetch is called with the extra positional args (a selector/labor name);
# reports that take no argument simply ignore them.
_REPORTS = {
    "briefing": (lambda *a: fetch_briefing(), format_briefing),
    "brewing": (lambda *a: fetch_brewing_intel(), format_report),
    "stock": (lambda *a: fetch_stock(" ".join(a) if a else None), format_stock),
    "acquire": (lambda *a: fetch_acquirable(a[0] if a else None),
                format_acquirable),
    "containers": (lambda *a: fetch_containers(), format_containers),
    "locate": (lambda *a: fetch_stockpile_locate(" ".join(a) if a else ""),
               format_stockpile_locate),
    "building": (lambda *a: fetch_building_locate(" ".join(a) if a else ""),
                 format_building_locate),
    "item": (lambda *a: fetch_item_detail(a[0] if a else ""), format_item_detail),
    "stockpile-config": (lambda *a: fetch_stockpile_config(),
                         format_stockpile_config),
    "building-config": (lambda *a: fetch_building_config(),
                        format_building_config),
    "shops": (lambda *a: fetch_shops_and_orders(), format_shops_and_orders),
    "diagnose": (lambda *a: fetch_brewing_diagnosis(), format_brewing_diagnosis),
    "livestock": (lambda *a: fetch_livestock_intel(), format_livestock_report),
    "livestock-diag": (lambda *a: fetch_livestock_diagnosis(),
                       format_livestock_diagnosis),
    "textiles": (lambda *a: fetch_textiles_intel(), format_textiles_report),
    "textiles-diag": (lambda *a: fetch_textiles_diagnosis(),
                      format_textiles_diagnosis),
    "roster": (lambda *a: fetch_roster(), format_roster),
    "mood": (lambda *a: fetch_mood(), format_mood),
    "zones": (lambda *a: fetch_zones_intel(), format_zones_report),
    "hotkeys": (lambda *a: fetch_hotkeys_intel(), format_hotkeys_report),
    "dwarf": (lambda *a: fetch_dwarf_detail(a[0] if a else ""),
              format_dwarf_detail),
    "labor": (lambda *a: fetch_labor_coverage(a[0] if a else "BREWER"),
              format_labor_coverage),
    "announcements": (lambda *a: fetch_announcements(int(a[0]) if a else 50),
                      format_announcements),
    "artifact": (lambda *a: fetch_artifact(a[0] if a else ""), format_artifact),
    "deity": (lambda *a: fetch_deity(a[0] if a else ""), format_deity),
    "faith": (lambda *a: fetch_faith(a[0] if a else ""), format_faith),
}


# Write ("act") subcommands. Each maps positional args to one mutation function;
# mode comes from flags (default 'advise'), and writes need both --apply and
# --confirm. These return text directly.
def _act_mode(argv: list[str]) -> str:
    if "--apply" in argv:
        return "apply"
    if "--preview" in argv:
        return "preview"
    return "advise"


def _parse_supplies(args: list[str]) -> dict:
    """Turn ['cloth','60','splints','5'] into {'cloth':60,'splints':5}."""
    if len(args) % 2 != 0:
        raise ValueError("hospital-supplies takes <field> <max> pairs")
    return {args[i]: int(args[i + 1]) for i in range(0, len(args), 2)}


_ACTIONS = {
    "queue-order": lambda a, m, c: queue_work_order(
        a[0], int(a[1]) if len(a) > 1 else 10,
        a[2] if len(a) > 2 else "any", mode=m, confirm=c),
    "stock-target": lambda a, m, c: auto_stock_target(
        a[0], int(a[1]), a[2] if len(a) > 2 else None, mode=m, confirm=c),
    "fix-idle": lambda a, m, c: fix_idle(mode=m, confirm=c),
    "containers-fix": lambda a, m, c: manage_containers(mode=m, confirm=c),
    "boost-mood": lambda a, m, c: boost_mood(mode=m, confirm=c),
    "hospital-supplies": lambda a, m, c: set_hospital_supplies(
        _parse_supplies(a), mode=m, confirm=c),
    "set-hotkey": lambda a, m, c: set_hotkey(
        int(a[0]), a[1] if len(a) > 1 else "",
        int(a[2]) if len(a) > 2 else 0,
        int(a[3]) if len(a) > 3 else 0,
        int(a[4]) if len(a) > 4 else 0,
        mode=m, confirm=c),
}


def main(argv: list[str]) -> int:
    want_json = "--json" in argv
    positionals = [a for a in argv if not a.startswith("--")]
    name = positionals[0] if positionals else "brewing"
    extra = positionals[1:]

    if name in _ACTIONS:
        mode = _act_mode(argv)
        confirm = "--confirm" in argv
        try:
            print(_ACTIONS[name](extra, mode, confirm))
        except DFHackError as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        except (IndexError, ValueError) as e:
            print(f"error: bad arguments for {name}: {e}", file=sys.stderr)
            return 2
        return 0

    if name not in _REPORTS:
        print(f"error: unknown report {name!r}; choose one of "
              f"{', '.join(_REPORTS)}", file=sys.stderr)
        return 2

    fetch, fmt = _REPORTS[name]
    try:
        data = fetch(*extra)
    except DFHackError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    if want_json:
        import json
        print(json.dumps(data, indent=2))
    else:
        print(fmt(data))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
