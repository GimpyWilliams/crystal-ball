"""
READ-ONLY caravan and trade intelligence for crystal-ball.

fetch_caravan_intel()      -- live RPC query of active caravans via DFHack
fetch_trade_history()      -- reads agent/data/trade_history.json (no RPC)
"""

import json
from pathlib import Path

from intel import as_map, run_intel
from reports import append_errors

_DATA_DIR    = Path(__file__).resolve().parent / "data"
HISTORY_PATH = _DATA_DIR / "trade_history.json"


def _ensure_data_dir() -> None:
    _DATA_DIR.mkdir(parents=True, exist_ok=True)


# ---------------------------------------------------------------------------
# Live caravan query
# ---------------------------------------------------------------------------

def fetch_caravan_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("caravan_intel.lua", host=host, port=port)


_MOOD_LABELS = {
    0: "hostile", 10: "very cold", 20: "cold", 30: "dismissive",
    40: "unfriendly", 50: "lukewarm", 60: "neutral", 70: "friendly",
    80: "receptive", 90: "warm", 100: "enthusiastic",
}

def _mood_label(mood: int | None) -> str:
    if mood is None:
        return "?"
    # find the closest label key
    best = min(_MOOD_LABELS, key=lambda k: abs(k - mood))
    return f"{_MOOD_LABELS[best]} ({mood})"


def format_caravan_report(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    lines = ["=== Active Caravan Report ==="]
    year = data.get("cur_year", "?")
    tick = data.get("cur_year_tick", "?")
    lines.append(f"Year {year}, tick {tick}")

    count    = data.get("caravan_count", 0)
    caravans = data.get("caravans") or []
    lines.append(f"\nActive caravans: {count}")

    if not caravans:
        lines.append("  (none present)")
    else:
        for c in caravans:
            name   = c.get("entity_name", "unknown")
            state  = c.get("trade_state", "?")
            mood   = _mood_label(c.get("mood"))
            ival   = c.get("import_value", 0)
            oval   = c.get("offer_value", 0)
            ticks  = c.get("time_remaining")
            items  = c.get("goods_item_count", 0)
            units  = c.get("goods_unit_count", 0)
            anims  = c.get("animals_count", 0)
            lines.append(f"\n  {name}")
            lines.append(f"    state: {state}  |  mood: {mood}")
            lines.append(f"    goods: {items} item types, {units} units"
                         + (f"  |  {anims} animal(s)" if anims else ""))
            lines.append(f"    import value: {ival}  |  offered so far: {oval}")
            if ticks is not None:
                lines.append(f"    time remaining: {ticks} ticks")

            goods = as_map(c.get("goods_by_type"))
            if goods:
                lines.append("    goods breakdown:")
                for tname, n in sorted(goods.items(), key=lambda kv: -kv[1]):
                    lines.append(f"      {n:>5}  {tname}")

    liaisons = data.get("liaisons") or []
    if liaisons:
        lines.append(f"\nLiaison meeting{'s' if len(liaisons) > 1 else ''}:")
        for li in liaisons:
            dname = li.get("diplomat_name") or f"hf#{li.get('diplomat_id', '?')}"
            cname = li.get("civ_name", "?")
            step  = li.get("cur_step", -1)
            evts  = li.get("events_count", 0)
            lines.append(f"  {dname} from {cname}"
                         f"  (step={step}, events={evts})")

    append_errors(lines, data)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Persistent trade history (local file, written by crystal-ball-trade-hook.lua)
# ---------------------------------------------------------------------------

def fetch_trade_history(limit: int = 100) -> dict:
    """Read the JSON log written by the DFHack hook. No RPC."""
    _ensure_data_dir()
    if not HISTORY_PATH.exists():
        return {
            "records": [], "total": 0, "shown": 0,
            "path_exists": False,
            "message": (
                f"No trade history yet. The DFHack hook writes here when a "
                f"caravan arrives: {HISTORY_PATH}. Make sure "
                f"crystal-ball-trade-hook.lua is in dfhack-config/scripts/ "
                f"and 'crystal-ball-trade-hook' is in "
                f"dfhack-config/init/onMapLoad.init."
            ),
        }
    try:
        records = json.loads(HISTORY_PATH.read_text(encoding="utf-8"))
        if not isinstance(records, list):
            records = []
    except (json.JSONDecodeError, OSError) as e:
        return {"records": [], "total": 0, "shown": 0,
                "path_exists": True, "error": str(e)}

    total         = len(records)
    shown_records = records[-limit:] if limit else records
    return {
        "records":     shown_records,
        "total":       total,
        "shown":       len(shown_records),
        "path_exists": True,
    }


def format_trade_history_report(data: dict) -> str:
    lines = ["=== Trade History (persistent caravan log) ==="]

    if msg := data.get("message"):
        lines.append(f"\n{msg}")
        return "\n".join(lines)
    if err := data.get("error"):
        lines.append(f"\nError reading history file: {err}")
        return "\n".join(lines)

    total   = data.get("total", 0)
    shown   = data.get("shown", 0)
    records = data.get("records") or []
    lines.append(f"\nShowing {shown} of {total} recorded arrival(s)")

    for r in records:
        year   = r.get("year", "?")
        tick   = r.get("tick", "?")
        name   = r.get("entity_name", "unknown")
        state  = r.get("trade_state", "?")
        mood   = r.get("mood")
        ival   = r.get("import_value")
        units  = r.get("goods_unit_count", 0)
        mood_s = f"  mood={mood}" if mood is not None else ""
        ival_s = f"  value={ival}" if ival is not None else ""
        lines.append(f"\n  [{year}/{tick}] {name}  ({state}){mood_s}{ival_s}")
        if units:
            lines.append(f"    goods: {units} units total")
        goods = as_map(r.get("goods_by_type"))
        for tname, n in sorted(goods.items(), key=lambda kv: -kv[1])[:8]:
            lines.append(f"      {n:>5}  {tname}")
        if len(goods) > 8:
            lines.append(f"      ... and {len(goods) - 8} more type(s)")

    if not records:
        lines.append("  (no arrivals on record)")

    return "\n".join(lines)
