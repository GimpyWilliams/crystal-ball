"""
Free-text -> concrete (item_type, subtype) / building predicate resolver, backed
by a cached snapshot of the loaded world's STATIC schema (scripts/dump_raws.lua).

This is the R0 foundation for the investigation tools. The DFHack item model is
type-aware but subtype-blind: every "available stock" path keys off
df.item_type[it:getType()], so the ~30 distinct TOOL objects (nest box, jug,
wheelbarrow, book, altar, ...) collapse into one bucket and a query for a
nonexistent type (NEST_BOX, BOOTS) hard-crashes the lookup. Resolving a human
name to a concrete (item_type, subtype) BEFORE the live query fixes both: the
query is narrowed (so per-instance output stays token-safe) and an unknown name
returns a clean suggestion instead of a Lua traceback.

The snapshot is static (fixed per world + mod-load), so it is dumped ONCE and
cached on disk as data/raws_<world_id>.json, keyed on the live world id. A cheap
"id" probe checks freshness each call; a mismatch (or missing cache) triggers a
re-dump. Read-only throughout -- the dump script mutates nothing.
"""

import difflib
import json
import re
from pathlib import Path

from intel import run_intel

# Split camelCase / PascalCase at a lower/digit -> upper boundary, so the
# CamelCase enum names ("NestBox", "WoodFurnace", "FarmPlot", "TradeDepot") match
# spaced free-text ("nest box", "wood furnace"). Harmless on all-caps item_type
# names and underscore-joined raw ids.
_CAMEL = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")

_DATA = Path(__file__).resolve().parent / "data"

# Which itemdef subtype table maps to which df.item_type enum name. The Lua dump
# (scripts/dump_raws.lua DEF_TABLES) snapshots these tables; here we attach each
# to the item_type whose subtypes it enumerates. A table whose item_type is not
# present in this world's enum dump is simply skipped (robust to build changes).
_TABLE_TO_TYPE = {
    "tools": "TOOL",
    "weapons": "WEAPON",
    "armor": "ARMOR",
    "shoes": "SHOES",
    "helms": "HELM",
    "gloves": "GLOVES",
    "pants": "PANTS",
    "shields": "SHIELD",
    "ammo": "AMMO",
    "siege_ammo": "SIEGEAMMO",
    "trapcomps": "TRAPCOMP",
    "toys": "TOY",
    "instruments": "INSTRUMENT",
    "food": "FOOD",
}

# In-memory cache: world_id -> snapshot dict. The MCP server is long-lived, so
# this avoids re-reading the disk file every resolve within one session.
_cache: dict = {}


class UnknownType(Exception):
    """A free-text type name could not be resolved; message carries suggestions."""


# --- snapshot load / refresh ----------------------------------------------

def _norm(s: str) -> str:
    """Normalize for matching: split camelCase, lowercase, collapse separators."""
    s = _CAMEL.sub(" ", str(s))
    return " ".join(s.lower().replace("_", " ").replace("-", " ").split())


def load(host: str = "127.0.0.1", port: int = 5000) -> dict:
    """Return the static-schema snapshot for the currently-loaded world.

    Cheap "id" probe first; reuse the in-memory / on-disk cache when it matches,
    otherwise dump the full raws and cache them. Raises UnknownType when no fort
    is loaded (there is then no world to resolve against).
    """
    meta = run_intel("dump_raws.lua", args=["id"], host=host, port=port)
    if not meta.get("fort_loaded"):
        raise UnknownType("no fort is loaded; load a fort to resolve item/building types")
    wid = meta.get("world_id")
    if wid in _cache:
        return _cache[wid]

    path = _DATA / f"raws_{wid}.json"
    if path.exists():
        snap = json.loads(path.read_text(encoding="utf-8"))
    else:
        snap = run_intel("dump_raws.lua", host=host, port=port)
        _DATA.mkdir(exist_ok=True)
        path.write_text(json.dumps(snap), encoding="utf-8")
    _cache[wid] = snap
    return snap


# --- item resolution -------------------------------------------------------

def resolve_item(text: str, host: str = "127.0.0.1", port: int = 5000):
    """Map a free-text item name to (item_type_name, subtype_index | None).

    Order of precedence:
      1. an exact df.item_type enum name ("DRINK", "thread")  -> (TYPE, None)
      2. an itemdef subtype matched by raw id / name / name_plural
         ("nest box", "ITEM_TOOL_NEST_BOX", "breastplate") -> (TYPE, index)
    Raises UnknownType with close-match suggestions on no match.
    """
    snap = load(host=host, port=port)
    item_types = snap.get("enums", {}).get("item_type", {})
    q = _norm(text)

    # 1. direct item_type enum name (case-insensitive)
    for name in item_types:
        if _norm(name) == q:
            return (name, None)

    # 2. itemdef subtype, matched on raw id / name / name_plural
    itemdefs = snap.get("itemdefs", {})
    for table, defs in itemdefs.items():
        type_name = _TABLE_TO_TYPE.get(table)
        if not type_name or type_name not in item_types:
            continue
        for d in defs:
            cands = (_norm(d.get("id", "")), _norm(d.get("name", "")),
                     _norm(d.get("name_plural", "")))
            if q in cands:
                return (type_name, d.get("i"))

    raise UnknownType(_suggest_item(q, item_types, snap.get("itemdefs", {})))


def _suggest_item(q: str, item_types: dict, itemdefs: dict) -> str:
    """Build a 'no such type; did you mean ...' message from close matches."""
    pool = {_norm(n): n for n in item_types}
    for defs in itemdefs.values():
        for d in defs:
            for key in ("name", "id"):
                v = d.get(key)
                if v:
                    pool.setdefault(_norm(v), v)
    hits = difflib.get_close_matches(q, list(pool), n=4, cutoff=0.5)
    # substring fallback when fuzzy finds nothing
    if not hits:
        hits = [orig for nrm, orig in pool.items() if q in nrm or nrm in q][:4]
    sugg = ", ".join(pool[h] if h in pool else h for h in hits)
    msg = f"unknown item type {q!r}"
    return f"{msg}; did you mean: {sugg}?" if sugg else f"{msg}"


# --- building resolution ---------------------------------------------------

# Subtype enums that live under a parent building_type. text matching a name in
# one of these resolves to (parent_building_type, subtype_index).
_BUILDING_SUBTYPE_ENUMS = {
    "Workshop": "workshop_type",
    "Furnace": "furnace_type",
    "Trap": "trap_type",  # levers, pressure plates, cage/stonefall/weapon traps
}


def resolve_building(text: str, host: str = "127.0.0.1", port: int = 5000):
    """Map a free-text building name to (building_type_name, subtype_index | None).

      1. an exact df.building_type enum name ("Bridge", "Well", "Floodgate")
      2. a workshop/furnace/trap subtype name ("Masons", "Smelter", "Lever")
         -> (parent type, subtype index)
    Raises UnknownType with suggestions on no match.
    """
    snap = load(host=host, port=port)
    enums = snap.get("enums", {})
    building_types = enums.get("building_type", {})
    q = _norm(text)

    # 1. direct building_type
    for name in building_types:
        if _norm(name) == q:
            return (name, None)

    # 2. subtype under a parent building_type
    for parent, enum_name in _BUILDING_SUBTYPE_ENUMS.items():
        if parent not in building_types:
            continue
        for sub_name, idx in enums.get(enum_name, {}).items():
            if _norm(sub_name) == q:
                return (parent, idx)

    # suggestions across building types + all subtype enums
    pool = {_norm(n): n for n in building_types}
    for enum_name in _BUILDING_SUBTYPE_ENUMS.values():
        for sub_name in enums.get(enum_name, {}):
            pool.setdefault(_norm(sub_name), sub_name)
    hits = difflib.get_close_matches(q, list(pool), n=4, cutoff=0.5)
    if not hits:
        hits = [orig for nrm, orig in pool.items() if q in nrm or nrm in q][:4]
    sugg = ", ".join(pool[h] if h in pool else h for h in hits)
    raise UnknownType(
        f"unknown building type {q!r}" + (f"; did you mean: {sugg}?" if sugg else ""))


# --- output tiering --------------------------------------------------------

def tier_mode(count: int, threshold: int = 50) -> str:
    """Choose per-instance vs aggregate output by result size.

    Because a resolved filter narrows the query up front, most results are small
    enough to list each instance with exact coordinates ('list'); only a broad
    match falls back to the compact summary+scatter ('summary'). Keeps
    per-instance output token-safe without the caller guessing in advance.
    """
    return "list" if count <= threshold else "summary"


def scatter(positions, top: int = 5) -> dict:
    """Aggregate (x,y,z) tuples into a token-cheap scatter summary: a by-z
    histogram and the busiest tiles. Shared by the locate formatters' 'summary'
    tier. `positions` is an iterable of (x, y, z)."""
    by_z: dict = {}
    by_tile: dict = {}
    n = 0
    for x, y, z in positions:
        n += 1
        by_z[z] = by_z.get(z, 0) + 1
        key = f"{x},{y},{z}"
        by_tile[key] = by_tile.get(key, 0) + 1
    top_tiles = sorted(by_tile.items(), key=lambda kv: -kv[1])[:top]
    return {
        "count": n,
        "tile_count": len(by_tile),
        "by_z": by_z,
        "top_tiles": [{"tile": t, "n": c} for t, c in top_tiles],
    }
