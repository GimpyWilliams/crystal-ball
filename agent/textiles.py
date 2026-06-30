"""
READ-ONLY intel for the textiles / clothing industry (thread -> cloth -> clothes).
Each function runs one bundled, audited Lua query through DFHack's RunCommand RPC
and formats the result. Nothing here changes game state.
"""

from intel import as_map, run_intel
from reports import append_errors, format_diagnosis, stock_line


# --- textiles: intel report ------------------------------------------------

def fetch_textiles_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("textiles_intel.lua", host=host, port=port)


def format_textiles_report(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    lines = ["=== Textiles / Clothing Report ==="]

    thread = as_map(data.get("thread"))
    lines.append("\n" + stock_line("Thread", thread, top_materials=6))

    cloth = as_map(data.get("cloth"))
    lines.append("\n" + stock_line("Cloth", cloth, top_materials=6))

    clo = as_map(data.get("clothing"))
    lines.append(f"\nClothing on hand: {clo.get('total', 0)} items "
                 f"({clo.get('tattered', 0)} tattered, {clo.get('worn', 0)} worn)")
    for tname, c in sorted(as_map(clo.get("by_type")).items()):
        tat = c.get("tattered", 0)
        note = f"  ({tat} tattered)" if tat else ""
        lines.append(f"  {c.get('count', 0):>4}  {tname}{note}")

    looms = as_map(data.get("looms"))
    clothiers = as_map(data.get("clothiers"))
    lines.append(f"\nLooms: {looms.get('count', 0)} ({looms.get('busy', 0)} busy)"
                 f"   Clothier's: {clothiers.get('count', 0)} "
                 f"({clothiers.get('busy', 0)} busy)")

    orders = as_map(data.get("orders"))
    lines.append(f"\nOrders: {orders.get('weave_left', 0)} cloth to weave, "
                 f"{orders.get('clothes_left', 0)} clothes to make")

    append_errors(lines, data)
    return "\n".join(lines)


# --- textiles: diagnosis ---------------------------------------------------

def fetch_textiles_diagnosis(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("diagnose_textiles.lua", host=host, port=port)


_TEXTILES_LABELS = {
    "loom_exists": "Loom built",
    "thread_available": "Thread on hand",
    "weaver_assigned": "A dwarf can/does weave",
    "clothier_exists": "Clothier's shop built",
    "cloth_available": "Cloth on hand",
    "clothesmaker_assigned": "A dwarf can/does sew clothes",
    "tattered_clothing": "Clothing not tattered",
}


def format_textiles_diagnosis(data: dict) -> str:
    return format_diagnosis(
        data, "=== Why aren't clothes being made? ===", _TEXTILES_LABELS,
        ("looms", "thread_free", "clothiers", "cloth_free", "tattered_clothing"),
        "if the textile chain is still stalled the cause is likely subtler (no "
        "thread source -- shear/process plants/collect webs -- a dye step, or a "
        "burrow/stockpile restriction)")
