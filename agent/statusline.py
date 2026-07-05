"""
Lightweight, low-latency snapshot for the Claude Code status line: citizen/mood
counts, key survival-stock levels (+ deltas since the last snapshot), and the
in-game clock/site name. Deliberately skips fort_briefing's industry
diagnose_* fan-out -- that's the slow part -- so this stays to a handful of
near-instant queries (roster, mood, key stocks) and is safe to run from a
background refresh on every status-line render.

Two entry points, both run from `.claude/statusline.sh`:
  refresh_cache()   -- hits DFHack live, writes data/statusline_cache.json.
                       Slow-ish (a socket round trip per query); always run
                       in the background, never inline in the status line.
  format_snapshot() -- reads the cache file only; no RPC. Fast enough to call
                       inline on every status-line render.

The cache is disk-only (matches stockcache.py's convention) and written
atomically (temp + os.replace) so a status-line read never sees a partial
write.
"""

import json
import sys
import time
from pathlib import Path

from intel import as_map, run_intel, shared_connection
from dwarves import fetch_roster
from mood import fetch_mood
from briefing import fetch_key_stocks, _STRESS_LIMIT

_CACHE = Path(__file__).resolve().parent / "data" / "statusline_cache.json"


def fetch_statusline_snapshot(host: str = "127.0.0.1", port: int = 5000) -> dict:
    """One shared_connection covering: clock/site name, roster, moods, key
    stocks. No industry diagnosis queries -- those are what makes fort_briefing
    slow, and this needs to stay cheap enough for a frequent background poll."""
    with shared_connection(host, port):
        clock = run_intel("statusline_intel.lua")
        if not clock.get("fort_loaded"):
            return {"fort_loaded": False}

        roster = as_map(fetch_roster())
        dwarves = roster.get("dwarves") or []
        moods_data = as_map(fetch_mood())
        stock_cats = as_map(fetch_key_stocks()).get("categories") or {}

    stock = {}
    for tname, cat in as_map(stock_cats).items():
        c = as_map(cat)
        stock[tname] = c.get("available", c.get("free_units", 0))

    return {
        "fort_loaded": True,
        "generated_at": time.time(),
        "site_name": clock.get("site_name"),
        "cur_year": clock.get("cur_year"),
        "citizens": {
            "count": roster.get("count", len(dwarves)),
            "idle": sum(1 for d in dwarves if d.get("activity") == "Idle"),
            "stressed": sum(1 for d in dwarves
                            if (d.get("stress") or 0) >= _STRESS_LIMIT),
            "wounded": sum(1 for d in dwarves if d.get("wounded")),
        },
        "moods": [
            {
                "name": m.get("name"),
                "insane": bool(m.get("insane")),
                "at_risk": bool(m.get("blocked_count") and m.get("productive")),
            }
            for m in (moods_data.get("moods") or [])
        ],
        "stock": stock,
    }


def refresh_cache(host: str = "127.0.0.1", port: int = 5000) -> dict:
    """Fetch a fresh snapshot, diff its key stocks against the previously
    cached snapshot for deltas, and atomically write the new cache. Never
    raises -- on any failure the cache just keeps serving the last snapshot
    it had, plus an error note the status line's format ignores."""
    prev = _load_raw()
    try:
        snap = fetch_statusline_snapshot(host, port)
    except Exception as e:  # noqa: BLE001 -- background refresh must not crash
        snap = {"fort_loaded": False, "generated_at": time.time(), "error": str(e)}

    if snap.get("fort_loaded") and prev.get("fort_loaded"):
        prev_stock = prev.get("stock") or {}
        cur_stock = snap.get("stock") or {}
        snap["stock_delta"] = {
            t: cur_stock[t] - prev_stock[t]
            for t in cur_stock
            if t in prev_stock and cur_stock[t] != prev_stock[t]
        }
    else:
        snap["stock_delta"] = {}

    _save_raw(snap)
    return snap


def format_snapshot(data: dict) -> str:
    """Render the cached snapshot as one compact status-line fragment. Pure
    formatting over already-fetched data -- no RPC, safe to call inline."""
    if not data or not data.get("fort_loaded"):
        return ""

    parts = []

    site = data.get("site_name")
    year = data.get("cur_year")
    if site or year is not None:
        label = site or "the fort"
        year_str = f" Y{year}" if year is not None else ""
        parts.append(f"\U0001F3F0 {label}{year_str}")

    cit = data.get("citizens") or {}
    if cit.get("count") is not None:
        bits = []
        if cit.get("idle"):
            bits.append(f"{cit['idle']} idle")
        if cit.get("stressed"):
            bits.append(f"{cit['stressed']} stressed")
        if cit.get("wounded"):
            bits.append(f"{cit['wounded']} wounded")
        suffix = f" ({', '.join(bits)})" if bits else ""
        parts.append(f"\U0001F9D1 {cit['count']}{suffix}")

    moods = data.get("moods") or []
    if moods:
        at_risk = sum(1 for m in moods if m.get("at_risk") or m.get("insane"))
        flag = "  [!]" if at_risk else ""
        plural = "s" if len(moods) != 1 else ""
        parts.append(f"\U0001F9E0 {len(moods)} mood{plural}{flag}")

    stock = data.get("stock") or {}
    empty = sorted(t for t, n in stock.items() if n == 0)
    if empty:
        parts.append("⚠ " + "/".join(empty[:3]) + " EMPTY")

    delta = data.get("stock_delta") or {}
    if delta:
        top = sorted(delta.items(), key=lambda kv: -abs(kv[1]))[:2]
        rendered = " ".join(f"{'+' if n > 0 else ''}{n} {t}" for t, n in top)
        parts.append(f"Δ {rendered}")

    return "  |  ".join(parts)


def _load_raw() -> dict:
    try:
        return json.loads(_CACHE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _save_raw(data: dict) -> None:
    _CACHE.parent.mkdir(parents=True, exist_ok=True)
    tmp = _CACHE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data), encoding="utf-8")
    tmp.replace(_CACHE)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "refresh":
        refresh_cache()
    else:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        print(format_snapshot(_load_raw()))
