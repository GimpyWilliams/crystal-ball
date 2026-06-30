"""
READ-ONLY intel for the building-materials industries: masonry, carpentry, glass,
and mechanisms. One bundled, audited Lua query per function through DFHack's
RunCommand RPC; nothing here changes game state.
"""

from intel import as_map, run_intel
from reports import append_errors, format_diagnosis


def fetch_construction_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("construction_intel.lua", host=host, port=port)


def _stk(d: dict, key: str) -> str:
    s = as_map(d.get(key))
    return f"{s.get('free_units', 0)} free / {s.get('total_units', 0)} total"


def format_construction_report(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    lines = ["=== Construction / Materials Report ==="]

    m = as_map(data.get("masonry"))
    lines.append(f"\nMasonry: {m.get('shops', 0)} mason's shop(s) "
                 f"({m.get('busy', 0)} busy)")
    lines.append(f"  blocks: {_stk(m, 'blocks')};  stone: {_stk(m, 'stone')}")

    c = as_map(data.get("carpentry"))
    lines.append(f"\nCarpentry: {c.get('shops', 0)} carpenter's shop(s) "
                 f"({c.get('busy', 0)} busy)")
    lines.append(f"  logs: {_stk(c, 'logs')}")

    g = as_map(data.get("glass"))
    lines.append(f"\nGlass: {g.get('furnaces', 0)} glass furnace(s) "
                 f"({g.get('busy', 0)} busy, {g.get('magma', 0)} magma)")
    lines.append(f"  raw glass: {_stk(g, 'raw_glass')}")

    me = as_map(data.get("mechanisms"))
    lines.append(f"\nMechanisms: {me.get('shops', 0)} mechanic's shop(s) "
                 f"({me.get('busy', 0)} busy)")
    lines.append(f"  mechanisms: {_stk(me, 'mechanisms')};  stone: {_stk(me, 'stone')}")

    o = as_map(data.get("orders"))
    lines.append(f"\nOrders: {o.get('blocks', 0)} blocks, "
                 f"{o.get('mechanisms', 0)} mechanisms, {o.get('glass', 0)} glass")

    append_errors(lines, data)
    return "\n".join(lines)


def fetch_construction_diagnosis(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("diagnose_construction.lua", host=host, port=port)


_CONSTRUCTION_LABELS = {
    "masonry_shop": "Masonry: shop built",
    "masonry_stone": "Masonry: stone on hand",
    "masonry_labor": "Masonry: a dwarf can mason",
    "carpentry_shop": "Carpentry: shop built",
    "carpentry_logs": "Carpentry: logs on hand",
    "carpentry_labor": "Carpentry: a dwarf can do carpentry",
    "mechanisms_shop": "Mechanisms: shop built",
    "mechanisms_stone": "Mechanisms: stone on hand",
    "mechanisms_labor": "Mechanisms: a dwarf can do mechanics",
    "glass_furnace": "Glass: furnace built",
    "glass_labor": "Glass: a dwarf can make glass",
    "glass_sand": "Glass: sand + fuel",
}


def format_construction_diagnosis(data: dict) -> str:
    return format_diagnosis(
        data, "=== What's blocking the building-materials industries? ===",
        _CONSTRUCTION_LABELS,
        ("stone_free", "logs_free", "mason_shops", "carpenter_shops",
         "mechanic_shops", "glass_furnaces"),
        "every materials chain with a workshop has its inputs and labor, so any "
        "shortfall is just missing workshops or queued orders")
