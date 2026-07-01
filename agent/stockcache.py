"""
On-disk stock baseline cache: broad ("every good") reads served cheaply from a
per-world snapshot, refreshed per-type only when stale, while targeted reads stay
live. The dynamic sibling of resolve.py's static raws cache.

WHY a cache: the full world.items.all classify scan is ~29k items / ~10s. Broad
questions shouldn't pay that every time, but stock evolves, so freshness must be
DECIDED, not assumed. A cheap probe (scripts/stock_probe.lua: clock + per-type
loose-vector lengths, milliseconds) drives a per-type decision: serve from the
baseline or refresh.

DISK-ONLY (no in-memory tier): the file read is sub-ms at ~120KB, and disk is the
only thing the per-tab stdio server processes share -- so reading it on every
broad call gives free multi-tab coherence. Writes are atomic (temp + os.replace)
so a tab reading mid-write never sees a half-file.

TYPE CLASSES (self-calibrated at rebuild, never hardcoded):
  "vector" -- loose-vector length ~= true count (drink, food, plants...). Cheap to
              refresh from world.items.other[TYPE]; short TTL (1 game-week).
  "heavy"  -- vector badly undercounts (BOOK 17 vs 12355, worn armor...) because
              the stock lives in containers/inventories. A correct refresh is
              ~a full scan, so these ride a long TTL (1 season) + full rebuilds.
"""

import json
import os
import tempfile
from pathlib import Path

from intel import as_map, run_intel, shared_connection

# DF time: 12 months * 28 days * 1200 ticks/day. cur_year/cur_year_tick are O(1).
TICKS_PER_YEAR = 403200
TTL_VECTOR = 8400      # 1 game-week  -- perishable / vector-complete types
TTL_HEAVY = 100800     # 1 season     -- container-heavy types (scan-only)

# Classification tolerance: a type is "vector" if its loose vector captures >= this
# fraction of its true count. Loose enough that a few carried/dead items don't flip
# a complete type to "heavy"; strict enough that BOOK (0.001) stays "heavy".
COMPLETE_RATIO = 0.9

# Drift: re-scan a vector type when its live vector length departs from the cached
# count by more than this (absolute OR fraction), catching within-TTL change.
DRIFT_ABS = 2
DRIFT_FRAC = 0.05

_DATA = Path(__file__).resolve().parent / "data"


def _tick(year, tick) -> int:
    return (year or 0) * TICKS_PER_YEAR + (tick or 0)


def _path(world_id) -> Path:
    return _DATA / f"stock_{world_id}.json"


def _classify(item_count: int, vector_len: int) -> str:
    """vector vs heavy from the merged total count and the loose-vector length."""
    if not item_count:
        return "vector"  # empty type: cheap default, reclassified if it grows
    hi = max(item_count, vector_len, 1)
    lo = min(item_count, vector_len)
    return "vector" if lo / hi >= COMPLETE_RATIO else "heavy"


def _drifted(probe_len: int, base_count: int) -> bool:
    return abs(probe_len - base_count) > max(DRIFT_ABS, DRIFT_FRAC * base_count)


# --- disk I/O --------------------------------------------------------------

def probe(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("stock_probe.lua", host=host, port=port)


def load_baseline(world_id) -> dict | None:
    """Read+parse the per-world baseline from disk (no in-memory cache, so a sibling
    tab's write is always seen). Missing or corrupt -> None (caller rebuilds)."""
    p = _path(world_id)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


def save_baseline(world_id, baseline: dict) -> None:
    """Atomic write: temp file in the same dir, then os.replace -- a concurrent
    reader (another tab) sees either the old file or the new one, never a partial."""
    _DATA.mkdir(exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(_DATA), prefix=f"stock_{world_id}.",
                               suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(baseline, f)
        os.replace(tmp, _path(world_id))
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


# --- assembly --------------------------------------------------------------

def _assemble(baseline: dict) -> dict:
    """Project a baseline into the dict shape format_stock consumes, dropping the
    per-type as_of bookkeeping and attaching freshness metadata."""
    types = as_map(baseline.get("types"))
    cats, total, oldest = {}, 0, None
    for tname, entry in types.items():
        cats[tname] = {k: v for k, v in entry.items()
                       if k not in ("as_of_year", "as_of_tick")}
        total += cats[tname].get("item_count", 0)
        ao = _tick(entry.get("as_of_year"), entry.get("as_of_tick"))
        oldest = ao if oldest is None else min(oldest, ao)
    return {"fort_loaded": True, "cached": True, "categories": cats,
            "total_items": total, "errors": [],
            "cur_year": baseline.get("cur_year"),
            "cur_year_tick": baseline.get("cur_year_tick"),
            "as_of_oldest_tick": oldest}


# --- rebuild / patch / broad ----------------------------------------------

def full_rebuild(host: str = "127.0.0.1", port: int = 5000) -> dict:
    """Full paginated scan -> classify every type -> stamp as_of -> persist. Seeds
    type_class from any prior baseline so a type that has gone to zero stays KNOWN
    (a known type never re-triggers a rebuild just by reappearing)."""
    from pipelines import _fetch_stock_full  # local import avoids import cycle
    with shared_connection(host, port):
        pr = probe(host, port)
        if not pr.get("fort_loaded"):
            return {"fort_loaded": False, "categories": {}, "total_items": 0}
        world_id = pr.get("world_id")
        data = _fetch_stock_full(host=host, port=port)
    year, tick = data.get("cur_year"), data.get("cur_year_tick")
    cats = as_map(data.get("categories"))

    prior = load_baseline(world_id) or {}
    tclass = dict(as_map(prior.get("type_class")))  # accumulate, never shrink
    types = {}
    for tname, c in cats.items():
        tclass[tname] = _classify(c.get("item_count", 0), c.get("vector_len", 0))
        entry = dict(c)
        entry["as_of_year"], entry["as_of_tick"] = year, tick
        types[tname] = entry

    baseline = {"world_id": world_id, "cur_year": year, "cur_year_tick": tick,
                "type_class": tclass, "types": types}
    save_baseline(world_id, baseline)
    return _assemble(baseline)


def patch_type(world_id, type_name: str, page: dict) -> None:
    """Warm one type from a live focused scan (called after targeted reads). Updates
    the count + as_of; leaves classification to full_rebuild. No-op if no baseline
    exists yet or the world id is unknown."""
    if world_id is None:
        return
    baseline = load_baseline(world_id)
    if not baseline or baseline.get("world_id") != world_id:
        return
    # CRITICAL: only warm vector-class types. A focused scan reads world.items.other
    # [TYPE], which badly undercounts container-heavy types (TOOL 26 vs 9242, BOOK),
    # so patching one from a targeted read would corrupt the baseline's true count.
    # Heavy types are refreshed only by full_rebuild. Unknown class -> skip too (a
    # full_rebuild will classify and count it correctly).
    if as_map(baseline.get("type_class")).get(type_name) != "vector":
        return
    c = as_map(page.get("categories")).get(type_name)
    entry = dict(c) if c is not None else {"item_count": 0, "available": 0,
                                           "on_hand": 0, "free_units": 0}
    # Preserve the raw vector_len for drift bookkeeping (focused scans don't emit
    # it); fall back to the prior value, else the focused count as a proxy.
    prev = as_map(baseline.get("types")).get(type_name, {})
    if "vector_len" not in entry:
        entry["vector_len"] = prev.get("vector_len", entry.get("item_count", 0))
    entry["as_of_year"] = page.get("cur_year")
    entry["as_of_tick"] = page.get("cur_year_tick")
    baseline.setdefault("types", {})[type_name] = entry
    save_baseline(world_id, baseline)


def get_broad(host: str = "127.0.0.1", port: int = 5000) -> dict:
    """Serve the broad ("every good") inventory from the baseline, refreshing only
    what's stale. Decision matrix:
      - no/empty/mismatched baseline       -> full rebuild
      - a never-classified type appeared    -> full rebuild (to classify it right)
      - any heavy type past TTL_HEAVY       -> full rebuild
      - else: focused-refresh vector types past TTL_VECTOR or whose vector drifted
      - else: serve the baseline untouched (zero scans)
    """
    pr = probe(host, port)
    if not pr.get("fort_loaded"):
        return {"fort_loaded": False, "categories": {}, "total_items": 0}
    world_id = pr.get("world_id")
    now = _tick(pr.get("cur_year"), pr.get("cur_year_tick"))
    vlens = as_map(pr.get("vector_lens"))

    baseline = load_baseline(world_id)
    if not baseline or baseline.get("world_id") != world_id:
        return full_rebuild(host, port)

    types = as_map(baseline.get("types"))
    tclass = as_map(baseline.get("type_class"))

    # A nonzero type never seen before can't be classified cheaply -> full rebuild.
    if any(t not in tclass for t in vlens):
        return full_rebuild(host, port)
    # Container-heavy types: scan-only, on the long clock.
    if any(tclass.get(t) == "heavy"
           and (now - _tick(e.get("as_of_year"), e.get("as_of_tick"))) > TTL_HEAVY
           for t, e in types.items()):
        return full_rebuild(host, port)

    # Vector types: cheap focused refresh when past TTL or the loose vector drifted.
    # Drift compares the live vector length against the stored vector_len (both raw
    # #other), NOT item_count -- item_count comes from items.all and folds in carried
    # items, which would look like perpetual drift and churn the gross count.
    stale = [t for t, e in types.items()
             if tclass.get(t) != "heavy"
             and ((now - _tick(e.get("as_of_year"), e.get("as_of_tick"))) > TTL_VECTOR
                  or _drifted(vlens.get(t, 0),
                              e.get("vector_len", e.get("item_count", 0))))]
    if stale:
        with shared_connection(host, port):
            for t in stale:
                page = run_intel("stock_query.lua", args=[t], host=host, port=port)
                c = as_map(page.get("categories")).get(t)
                entry = dict(c) if c is not None else {
                    "item_count": 0, "available": 0, "on_hand": 0, "free_units": 0}
                # Focused scans don't emit vector_len; track it from the probe so the
                # next drift check stays like-for-like.
                entry["vector_len"] = vlens.get(t, entry.get("item_count", 0))
                entry["as_of_year"] = page.get("cur_year")
                entry["as_of_tick"] = page.get("cur_year_tick")
                types[t] = entry
        baseline["cur_year"] = pr.get("cur_year")
        baseline["cur_year_tick"] = pr.get("cur_year_tick")
        save_baseline(world_id, baseline)

    return _assemble(baseline)
