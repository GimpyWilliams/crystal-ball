"""
READ-ONLY industrial-pipeline reports: generic stock, container/storage audit,
and workshop + manager-order status. Each function runs one bundled, audited
Lua query (scripts/*.lua) and formats the result. Nothing here changes game
state, and no command string is ever taken from a caller.
"""

from intel import as_map, run_intel, shared_connection
from reports import stock_line
from resolve import UnknownType, resolve_building, resolve_item, tier_mode

# --- generic stock ---------------------------------------------------------

# Items per paginated full-scan chunk. At the measured ~0.34ms/item classify
# cost this is ~2s/chunk -- a comfortable margin under the 5s socket timeout,
# scaling to any fort size without ever tripping it (the unpaginated whole-fort
# scan ran ~10s and timed out).
_STOCK_CHUNK = 6000

# Per-type scalar counters that sum across pages, and the nested name->count maps
# that merge by summing values. Kept in lockstep with stock_query.lua's `account`.
_CAT_SCALARS = ("total_units", "item_count", "on_hand", "available",
                "free_units", "in_transit", "owned_unavailable", "inert",
                "not_yet_acquired", "acquirable")
_CAT_MAPS = ("by_material", "by_material_on_hand", "by_material_unowned",
             "by_reason_owned", "by_reason_unowned", "by_subtype")


def _merge_stock_categories(acc: dict, page_cats: dict) -> None:
    """Fold one page's per-type categories into the running accumulator: sum the
    scalar counters and merge the name->count maps. by_subtype values are
    {on_hand, available} sub-dicts (focus mode only; empty in a full scan)."""
    for tname, c in as_map(page_cats).items():
        a = acc.setdefault(tname, {})
        for k in _CAT_SCALARS:
            a[k] = a.get(k, 0) + c.get(k, 0)
        for mapname in _CAT_MAPS:
            dst = a.setdefault(mapname, {})
            for key, val in as_map(c.get(mapname)).items():
                if isinstance(val, dict):
                    sub = dst.setdefault(key, {})
                    for sk, sv in val.items():
                        sub[sk] = sub.get(sk, 0) + sv
                else:
                    dst[key] = dst.get(key, 0) + val


def fetch_stock(item_type: str | None = None, host: str = "127.0.0.1",
                port: int = 5000, rebuild: bool = False) -> dict:
    # No focus -> broad "every good" inventory, served from the on-disk baseline
    # (stockcache) and refreshed per-type only when stale; rebuild=True forces a
    # full re-scan. With a focus, resolve the free-text name and scan only that one
    # type's vector live -- the fast path -- then warm the baseline with the result.
    if not item_type:
        import stockcache  # local import: stockcache lazily imports back into us
        return (stockcache.full_rebuild(host=host, port=port) if rebuild
                else stockcache.get_broad(host=host, port=port))
    with shared_connection(host=host, port=port):
        try:
            type_name, subtype = resolve_item(item_type)
        except UnknownType as e:
            return {"fort_loaded": True, "error": str(e), "query": item_type}
        args = [type_name] + ([str(subtype)] if subtype is not None else [])
        data = run_intel("stock_query.lua", args=args)
        # Warm the baseline from this live, authoritative single-type count. Only
        # when unfiltered by subtype (a subtype slice isn't the whole type's count).
        if subtype is None and data.get("fort_loaded"):
            try:
                import stockcache
                stockcache.patch_type(data.get("world_id"), type_name, data)
            except Exception:  # noqa: BLE001 -- warming must never break a read
                pass
    data["query"] = item_type
    data["resolved_type"] = type_name
    data["resolved_subtype"] = subtype
    return data


def _fetch_stock_full(host: str = "127.0.0.1", port: int = 5000) -> dict:
    """Full-fort inventory by paging world.items.all in _STOCK_CHUNK-sized index
    ranges over one shared connection, merging each page's categories. Each RPC
    stays under the socket timeout; the merge reconstructs the same totals the
    old single-shot scan produced, but for every item."""
    merged: dict = {}
    out = {"fort_loaded": True, "total_items": 0, "categories": merged,
           "errors": []}
    with shared_connection(host=host, port=port):
        start = 0
        while True:
            page = run_intel("stock_query.lua",
                             args=["", str(start), str(_STOCK_CHUNK)])
            if not page.get("fort_loaded"):
                return page  # no fort loaded -> surface the bare report as-is
            _merge_stock_categories(merged, page.get("categories"))
            # Per-type vector_len is the FULL loose-vector length (page-independent),
            # so take the first occurrence rather than letting the merge sum it.
            for tname, c in as_map(page.get("categories")).items():
                if "vector_len" in c and "vector_len" not in merged.get(tname, {}):
                    merged[tname]["vector_len"] = c["vector_len"]
            out["total_items"] += page.get("total_items", 0)
            out["errors"].extend(page.get("errors") or [])
            out["scanned_total"] = page.get("scanned_total")
            # Clock + world id are identical on every page; keep the latest.
            out["cur_year"] = page.get("cur_year")
            out["cur_year_tick"] = page.get("cur_year_tick")
            out["world_id"] = page.get("world_id")
            cursor = page.get("next_cursor")
            if not cursor:
                break
            start = cursor
    return out


_SEASONS = ("spring", "summer", "autumn", "winter")


def _game_date(year, tick) -> str:
    """'Year 253, early summer'-style stamp from cur_year / cur_year_tick."""
    if year is None:
        return "unknown date"
    month = (tick or 0) // (1200 * 28)          # 0..11
    season = _SEASONS[min(month // 3, 3)]
    phase = ("early", "mid", "late")[month % 3]
    return f"Year {year}, {phase} {season}"


def format_stock(data: dict, top_materials: int = 6) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."
    if data.get("error"):
        return f"Error: {data['error']}"

    cats = as_map(data.get("categories"))
    lines = [f"=== Stock Inventory ({data.get('total_items', 0)} items, "
             f"{len(cats)} item types) ==="]
    if data.get("cached"):
        stamp = _game_date(data.get("cur_year"), data.get("cur_year_tick"))
        lines.append(f"(cached baseline as of {stamp}; perishables refresh within "
                     f"~1 week, books/tools within ~1 season -- "
                     f"query one item_type for a live count)")
    # Order categories by what the fort can use now (available), then by owned
    # stock -- NOT by gross total, so a pile of uncollected webs can't float a
    # category to the top as if it were usable.
    ordered = sorted(
        cats.items(),
        key=lambda kv: (-kv[1].get("available", kv[1].get("free_units", 0)),
                        -kv[1].get("on_hand", 0)),
    )
    for tname, c in ordered:
        # Lead with the owned (on-hand) block; not-yet-acquired and its materials
        # are nested within their own section by stock_line.
        lines.append("\n" + stock_line(tname, c, top_materials=top_materials))
        # Focused query: itemize the type's subtypes (nest box vs jug vs book).
        bysub = as_map(c.get("by_subtype"))
        if bysub:
            lines.append("  by subtype:")
            for label, s in sorted(bysub.items(),
                                   key=lambda kv: -kv[1].get("on_hand", 0)):
                lines.append(f"    {s.get('on_hand', 0):>5} on hand "
                             f"({s.get('available', 0)} available)  {label}")

    _append_errors(lines, data)
    return "\n".join(lines)


# --- container / storage audit --------------------------------------------

def fetch_containers(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("container_audit.lua", host=host, port=port)


_CONTAINER_LABELS = [
    ("barrels", "Barrels"),
    ("large_pots", "Large pots"),
    ("bins", "Bins"),
    ("bags", "Bags"),
    ("chests", "Chests/coffers"),
]


def format_containers(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."

    lines = ["=== Container / Storage Audit ==="]
    for key, label in _CONTAINER_LABELS:
        c = as_map(data.get(key))
        total = c.get("total", 0)
        if total == 0:
            lines.append(f"\n{label}: none")
            continue
        empty = c.get("empty", 0)
        partial = c.get("partial", 0)
        full = c.get("full", 0)
        forbid = c.get("forbidden", 0)
        avg = c.get("avg_fill_pct", 0)
        # No empty container of a kind = that storage is starved (the stall).
        note = "  <-- none empty; this storage is full" if empty == 0 else ""
        forbid_note = f", {forbid} forbidden" if forbid else ""
        lines.append(
            f"\n{label}: {total} total -- {empty} empty, {partial} partial, "
            f"{full} full (>=90%){forbid_note}; avg {avg}% full{note}")

    # The actionable bit: specific (nearly-)full containers, with where + coords.
    attention = data.get("attention") or []
    if attention:
        lines.append("\nNearly-full containers:")
        for a in attention:
            p = a.get("pos")
            pos_str = f" ({p['x']},{p['y']},{p['z']})" if p else ""
            where = a.get("where") or "?"
            lines.append(f"  {a.get('fill_pct', 0):>3}%  {a.get('kind','?')} "
                         f"of {a.get('material','?')} @ {where}{pos_str}")

    _append_errors(lines, data)
    return "\n".join(lines)


# --- workshops + manager orders -------------------------------------------

def fetch_shops_and_orders(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("shops_and_orders.lua", host=host, port=port)


# Readable verbs/nouns for common manager job types. Anything not listed falls
# back to a de-CamelCased form of the raw enum, so new job types still read OK.
_JOB_TYPE_LABELS = {
    "ConstructBlocks": "Cut Blocks",
    "ConstructBag": "Sew Bag",
    "MakeGoblet": "Make Goblet",
    "PrepareRawFish": "Prepare Raw Fish",
    "ProcessPlants": "Process Plants",
    "CollectWebs": "Collect Webs",
    "MakeBarrel": "Make Barrel",
    "MakeCharcoal": "Make Charcoal",
    "WeaveCloth": "Weave Cloth",
    "MakeTool": "Make Tool",
    "BrewDrink": "Brew Drink",
    "SmeltOre": "Smelt Ore",
}


def _decamel(name: str) -> str:
    """Fallback humanizer: 'ConstructBlocks' -> 'Construct Blocks'."""
    out = []
    for i, ch in enumerate(name):
        if i and ch.isupper() and not name[i - 1].isupper():
            out.append(" ")
        out.append(ch)
    return "".join(out)


def _order_label(o: dict) -> str:
    """Compose a human-readable label for one manager order."""
    # Custom reactions carry their own readable name; prefer it.
    base = o.get("reaction_name")
    if not base:
        jt = o.get("job_type", "?")
        base = _JOB_TYPE_LABELS.get(jt, _decamel(jt))

    mat = o.get("material")
    if mat:
        # The generic "stone" material class reads more naturally as "rock".
        # Match only the standalone category token (a "+"-joined list from Lua)
        # so concrete materials like "limestone"/"sandstone" are left intact.
        mat = "+".join("rock" if t == "stone" else t for t in mat.split("+"))
    label = f"{base} ({mat or 'any'})"

    ws = o.get("workshop")
    if ws:
        label += f" @{ws}"
    return label


def format_shops_and_orders(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."

    lines = ["=== Workshops & Manager Orders ==="]

    shops = as_map(data.get("workshops"))
    lines.append("\nWorkshops:")
    if shops:
        for tname, s in sorted(shops.items(), key=lambda kv: -kv[1].get("count", 0)):
            susp = s.get("suspended_jobs", 0)
            susp_note = f", {susp} suspended job(s)" if susp else ""
            lines.append(f"  {tname}: {s.get('count', 0)} built "
                         f"({s.get('idle', 0)} idle, {s.get('busy', 0)} busy"
                         f"{susp_note})")
    else:
        lines.append("  (none built)")

    orders = data.get("orders") or []
    lines.append(f"\nManager orders: {len(orders)}")
    for o in orders:
        flags = []
        if o.get("active") is False:
            flags.append("INACTIVE")
        if o.get("validated") is False:
            flags.append("not validated")
        freq = o.get("frequency")
        if freq and freq != "one-time":
            flags.append(f"repeat: {freq}")
        flag_note = f"  [{', '.join(flags)}]" if flags else ""
        lines.append(f"  {_order_label(o)}: "
                     f"{o.get('amount_left', 0)}/{o.get('amount_total', 0)} "
                     f"left{flag_note}")
        for cond in o.get("conditions") or []:
            lines.append(f"      condition: when {cond}")
    if not orders:
        lines.append("  (queue is empty)")

    _append_errors(lines, data)
    return "\n".join(lines)


# --- stockpile locate ------------------------------------------------------

def fetch_stockpile_locate(item_type: str, host: str = "127.0.0.1",
                            port: int = 5000) -> dict:
    # Resolve free-text ("nest box") to a concrete (item_type, subtype) BEFORE
    # the query, sharing one connection across the resolve + locate calls. An
    # unknown name returns a clean suggestion instead of crashing the lookup.
    with shared_connection(host=host, port=port):
        try:
            type_name, subtype = resolve_item(item_type)
        except UnknownType as e:
            return {"fort_loaded": True, "error": str(e), "query": item_type}
        args = [type_name] + ([str(subtype)] if subtype is not None else [])
        data = run_intel("stockpile_locate.lua", args=args)
    data["query"] = item_type
    data["resolved_type"] = type_name
    data["resolved_subtype"] = subtype
    return data


def format_stockpile_locate(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."
    if data.get("error"):
        return f"Error: {data['error']}"

    total_items = data.get("total_items", 0)
    total_units = data.get("total_units", 0)

    # Header echoes the resolved type/subtype so a free-text query is traceable.
    rtype = data.get("resolved_type", data.get("item_type", "?"))
    sub = data.get("resolved_subtype")
    label = rtype if sub is None else f"{rtype} subtype {sub}"
    q = data.get("query")
    qnote = f"{q!r} -> " if q and str(q).upper() != str(rtype).upper() else ""
    lines = [f"=== {qnote}{label} "
             f"({total_items} items, {total_units} stack units) ==="]

    if total_items == 0:
        lines.append("\n  (none found — none placed, in a stockpile, carried, "
                     "or loose on the ground)")
        _append_errors(lines, data)
        return "\n".join(lines)

    # AUTO-TIER: few results -> list each with exact coords; many -> aggregate.
    if tier_mode(total_items) == "list" and not data.get("items_capped"):
        for it in data.get("items") or []:
            p = it.get("pos")
            pos_str = f"({p['x']},{p['y']},{p['z']})" if p else "[carried]"
            cnt = it.get("n", 1)
            cnt_str = f" x{cnt}" if cnt and cnt > 1 else ""
            lines.append(f"  {pos_str:<16} {it.get('where', '?')}{cnt_str}")
        _append_errors(lines, data)
        return "\n".join(lines)

    # SUMMARY tier: named stockpiles, buildings, and unit carriers.
    named = data.get("locations") or []
    for loc in named:
        p = loc.get("pos")
        pos_str = f" at ({p['x']},{p['y']},{p['z']})" if p else ""
        lines.append(f"\n  {loc['label']}{pos_str}")
        lines.append(f"    {loc['item_count']} items  /  "
                     f"{loc['stack_units']} stack units")

    # Ground (loose, not in any stockpile) — summarised, never a single point.
    ground = data.get("ground")
    if ground:
        sp_count = data.get("stockpile_count", 0)
        if sp_count == 0 and total_items > 0:
            lines.append(
                f"\n  *** NO STOCKPILE — all {total_items} items are loose "
                f"on open ground ***")
        else:
            lines.append(f"\n  Open ground (no stockpile)")
        lines.append(f"    {ground['item_count']} items across "
                     f"{ground['tile_count']} distinct tiles")

        # Z-level distribution (sorted desc by stack count).
        by_z = ground.get("by_z") or {}
        if by_z:
            sorted_z = sorted(by_z.items(), key=lambda kv: -kv[1])
            z_parts = [f"z={z}: {n}" for z, n in sorted_z[:8]]
            lines.append(f"    by z-level: {', '.join(z_parts)}"
                         + (" ..." if len(sorted_z) > 8 else ""))

    if not named and not ground:
        lines.append("  (none found)")

    _append_errors(lines, data)
    return "\n".join(lines)


# --- building locate -------------------------------------------------------

def fetch_building_locate(building_type: str, host: str = "127.0.0.1",
                          port: int = 5000) -> dict:
    # Resolve free-text ("smelter", "lever", "nest box") to a building_type
    # (+ optional subtype) before the query, over one shared connection.
    with shared_connection(host=host, port=port):
        try:
            type_name, subtype = resolve_building(building_type)
        except UnknownType as e:
            return {"fort_loaded": True, "error": str(e), "query": building_type}
        args = [type_name] + ([str(subtype)] if subtype is not None else [])
        data = run_intel("building_locate.lua", args=args)
    data["query"] = building_type
    data["resolved_type"] = type_name
    data["resolved_subtype"] = subtype
    return data


def format_building_locate(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."
    if data.get("error"):
        return f"Error: {data['error']}"

    total = data.get("total", 0)
    built = data.get("built", 0)
    busy = data.get("busy", 0)
    rtype = data.get("resolved_type", "?")
    sub = data.get("resolved_subtype")
    label = rtype if sub is None else f"{rtype} subtype {sub}"
    q = data.get("query")
    qnote = f"{q!r} -> " if q and _norm_cmp(q) != _norm_cmp(rtype) else ""

    head = f"=== {qnote}{label} ({total} built/placed"
    unbuilt = total - built
    if unbuilt > 0:
        head += f", {unbuilt} under construction"
    if busy:
        head += f", {busy} busy"
    head += ") ==="
    lines = [head]

    if total == 0:
        lines.append("\n  (none found)")
        _append_errors(lines, data)
        return "\n".join(lines)

    # AUTO-TIER: few -> list each with coords + state; many -> by-subtype summary.
    if tier_mode(total) == "list" and not data.get("items_capped"):
        for it in data.get("items") or []:
            p = it.get("pos") or {}
            pos_str = f"({p.get('x')},{p.get('y')},{p.get('z')})"
            tags = []
            if it.get("subtype"):
                tags.append(it["subtype"])
            if not it.get("built"):
                tags.append("UNDER CONSTRUCTION")
            if it.get("job"):
                tags.append(f"job: {it['job']}")
            elif it.get("busy"):
                tags.append("busy")
            tag_str = ("  " + ", ".join(tags)) if tags else ""
            lines.append(f"  {pos_str:<16}{tag_str}")
    else:
        lines.append("")
        by_sub = as_map(data.get("by_subtype"))
        for name, n in sorted(by_sub.items(), key=lambda kv: -kv[1]):
            lines.append(f"  {n:>4}  {name}")
        if data.get("items_capped"):
            lines.append(f"  (per-instance coords omitted — {total} is a lot; "
                         f"filter by subtype to list them)")

    _append_errors(lines, data)
    return "\n".join(lines)


def _norm_cmp(s: str) -> str:
    """Loose compare for the header echo (camelCase/space/underscore-insensitive)."""
    return "".join(str(s).lower().split()).replace("_", "")


# --- acquirable items (the inverse of "available stock") -------------------

def fetch_acquirable(item_type: str | None = None, host: str = "127.0.0.1",
                     port: int = 5000) -> dict:
    args = [item_type.upper()] if item_type else None
    return run_intel("acquirable_items.lua", args=args, host=host, port=port)


# The two ownership groups, ordered most-actionable first within each. "loose"
# is reachable-but-unstockpiled (the fort owns it, a hauler just hasn't stored
# it). Anything not listed falls into a trailing "other" group so new reasons
# still render.
_OWNED_ORDER = ["loose", "claimed_job", "carried", "forbidden", "dumped", "melt"]
_UNOWNED_ORDER = ["uncollected_web", "loose_unreachable", "trade"]


def format_acquirable(data: dict, top_tiles: int = 5, top_mats: int = 4) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."
    if data.get("error"):
        return f"Error: {data['error']}"

    itype = data.get("item_type", "ALL")
    lines = [f"=== Acquirable {itype} (recoverable, not freely available) ==="]

    buckets = data.get("buckets") or []
    by_reason = {b.get("reason"): b for b in buckets}
    total_units = sum(b.get("units", 0) for b in buckets)
    if total_units == 0:
        lines.append("\n  Nothing to recover -- all stock is available, in "
                     "transit, or inert.")
    else:
        lines.append(f"\n{total_units} stack units across "
                     f"{len(buckets)} acquisition state(s):")

    def render_bucket(b):
        lines.append(f"\n  {b.get('reason')}: {b.get('units', 0)} units "
                     f"({b.get('items', 0)} stacks)")
        if b.get("hint"):
            lines.append(f"    -> {b['hint']}")
        mats = b.get("top_materials") or []
        if mats:
            mat_str = ", ".join(f"{m['units']} {m['material']}"
                                for m in mats[:top_mats])
            lines.append(f"    materials: {mat_str}")
        by_z = as_map(b.get("by_z"))
        if by_z:
            sz = sorted(by_z.items(), key=lambda kv: -kv[1])
            z_str = ", ".join(f"z={z}: {n}" for z, n in sz[:8])
            lines.append(f"    by z-level: {z_str}"
                         + (" ..." if len(sz) > 8 else ""))
        tiles = b.get("top_tiles") or []
        if tiles:
            t_str = "; ".join(f"({t['tile']}): {t['units']}"
                              for t in tiles[:top_tiles])
            lines.append(f"    busiest tiles: {t_str}")

    # Group by ownership so "owned but locked" (recover with a toggle/finished
    # job) is never blurred with "not owned yet" (gather/trade/dig to acquire).
    known = set(_OWNED_ORDER) | set(_UNOWNED_ORDER)
    groups = [
        ("Owned, but locked (recover with a flag toggle or finished job):",
         _OWNED_ORDER),
        ("Not owned yet (must gather / trade / dig to acquire):",
         _UNOWNED_ORDER),
        ("Other:", [r for r in by_reason if r not in known]),
    ]
    for header, order in groups:
        present = [by_reason[r] for r in order if r in by_reason]
        if not present:
            continue
        subtotal = sum(b.get("units", 0) for b in present)
        lines.append(f"\n{header}  ({subtotal} units)")
        for b in present:
            render_bucket(b)

    carriers = data.get("carriers") or []
    if carriers:
        lines.append("\nCarried by:")
        for c in carriers:
            lines.append(f"  {c.get('units', 0):>4}  {c.get('name', '?')}")

    # Reconciliation: show the full classifier histogram so available + in-transit
    # + acquirable + inert ties out against the total.
    states = as_map(data.get("states"))
    if states:
        fg = data.get("fort_walk_group")
        lines.append(f"\nState histogram (fort walk group = {fg}):")
        for st, e in sorted(states.items(), key=lambda kv: -kv[1].get("units", 0)):
            lines.append(f"  {e.get('units', 0):>6}  {st}  "
                         f"({e.get('items', 0)} stacks)")

    _append_errors(lines, data)
    return "\n".join(lines)


# --- stockpile / building configuration ------------------------------------

def fetch_stockpile_config(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("stockpile_config.lua", host=host, port=port)


def format_stockpile_config(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."
    if data.get("error"):
        return f"Error: {data['error']}"

    piles = data.get("stockpiles") or []
    lines = [f"=== Stockpile Configuration ({len(piles)} stockpiles) ==="]
    for sp in sorted(piles, key=lambda s: s.get("number", 0)):
        p = sp.get("pos")
        pos_str = f" ({p['x']},{p['y']},{p['z']})" if p else ""
        name = sp.get("name") or f"Stockpile #{sp.get('number', '?')}"
        lines.append(f"\n{name}{pos_str}")
        accepts = sp.get("accepts") or []
        lines.append(f"  accepts: {', '.join(accepts) if accepts else '(nothing enabled)'}")
        links = []
        if sp.get("links_give"):
            links.append(f"{sp['links_give']} give-to")
        if sp.get("links_take"):
            links.append(f"{sp['links_take']} take-from")
        if links:
            lines.append(f"  links: {', '.join(links)}")
        caps = []
        for key, label in (("max_bins", "bins"), ("max_barrels", "barrels"),
                           ("max_wheelbarrows", "wheelbarrows")):
            if sp.get(key) is not None:
                caps.append(f"{label}={sp[key]}")
        if caps:
            lines.append(f"  caps: {', '.join(caps)}")
    _append_errors(lines, data)
    return "\n".join(lines)


def fetch_building_config(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("building_config.lua", host=host, port=port)


def format_building_config(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."
    if data.get("error"):
        return f"Error: {data['error']}"

    lines = ["=== Zone / Room Assignments ==="]
    by_type = as_map(data.get("by_type"))
    if by_type:
        lines.append("\nBy zone type (assigned / total):")
        for ztype, t in sorted(by_type.items()):
            a = t.get("assigned", 0)
            tot = a + t.get("unassigned", 0)
            lines.append(f"  {ztype}: {a}/{tot} assigned")

    assignments = data.get("assignments") or []
    if assignments:
        lines.append("\nAssigned zones:")
        for z in assignments:
            p = z.get("pos")
            pos_str = f" ({p['x']},{p['y']},{p['z']})" if p else ""
            who = z.get("unit") or f"unit #{z.get('unit_id')}"
            lines.append(f"  {z.get('zone_type', '?')}{pos_str} -> {who}")
    else:
        lines.append("\n(no zones are assigned to a specific unit)")
    _append_errors(lines, data)
    return "\n".join(lines)


# --- item detail (inspect one item by id) ----------------------------------

def fetch_item_detail(item_id, host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("item_detail.lua", args=[str(item_id)], host=host, port=port)


def format_item_detail(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."
    if data.get("error"):
        return f"Error: {data['error']}"

    it = as_map(data.get("item"))
    if not it:
        return "Error: no item data returned."

    desc = it.get("description") or "?"
    lines = [f"=== Item #{it.get('id')}: {desc} ==="]

    type_str = it.get("type", "?")
    if it.get("subtype") is not None:
        type_str += f" (subtype {it['subtype']})"
    lines.append(f"  type:      {type_str}")
    lines.append(f"  material:  {it.get('material', '?')}")
    if it.get("quality"):
        lines.append(f"  quality:   {it['quality']}")
    if it.get("wear"):
        lines.append(f"  wear:      level {it['wear']}")
    if it.get("stack_size", 1) and it.get("stack_size", 1) > 1:
        lines.append(f"  stack:     {it['stack_size']}")

    lines.append(f"  state:     {it.get('state', '?')}")
    p = it.get("pos")
    if p:
        lines.append(f"  position:  ({p['x']},{p['y']},{p['z']})")
    if it.get("container"):
        lines.append(f"  inside:    {it['container']}")
    if it.get("holder"):
        lines.append(f"  carried by:{it['holder']}")
    if it.get("job"):
        lines.append(f"  job:       reserved by {it['job']}")
    flags = it.get("flags") or []
    if flags:
        lines.append(f"  flags:     {', '.join(flags)}")

    _append_errors(lines, data)
    return "\n".join(lines)


# --- shared ----------------------------------------------------------------

def _append_errors(lines: list, data: dict) -> None:
    errs = data.get("errors") or []
    if errs:
        lines.append("\nNote -- some sections could not be read:")
        for e in errs:
            lines.append(f"  - {e}")
