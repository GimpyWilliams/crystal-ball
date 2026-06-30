# Investigation Tools — Ranked Roadmap

Status: **R0–R6 IMPLEMENTED** (2026-06-29). Foundation + all six items shipped and
verified against a live fort; the full `mcp_server.py --selftest` passes with the
new tools wired in.
Scope: the stockpile / inventory / building investigation cluster of the
`crystal-ball` MCP server.

## Implementation summary (what shipped)

- **R0** `scripts/dump_raws.lua` + `resolve.py` (`resolve_item`,
  `resolve_building`, `tier_mode`, `scatter`, `UnknownType`) + `item_subtype()`
  prelude helper. Snapshot cached to `data/raws_<world_id>.json`.
- **R1** `stockpile_locate` hardened (pcall'd lookup) + subtype filter + auto-tier
  (per-instance coords ≤50, summary scatter above); item ids in the detail list.
- **R2** `building_locate` (new) — positions, build stage, current job; resolves
  workshop/furnace/trap subtypes.
- **R3** `stock_report(item_type=…)` focused fast path + per-subtype breakdown.
- **R4** `container_report` capacity-aware fill % + bags split from chests +
  nearly-full list with stockpile/coords.
- **R5** `stockpile_config` (accept categories, links, best-effort caps) +
  `building_config` (civzone room assignments by unit). Best-effort per-field.
- **R6** `item_detail(id)` (new) — material/quality/wear/state/container/job.
- New MCP tools all have `_report`/`_data` (or text/`_data`) twins + CLI
  subcommands (`locate`, `building`, `item`, `stock <q>`, `stockpile-config`,
  `building-config`) + selftest coverage.

Remaining/optional follow-ups: `max_bins`/`max_barrels` fields are absent on this
DF build (R5 caps degrade to omitted); revisit if a build exposes them.

## Background — the root finding

The system is **type-aware but subtype-blind and building-blind.** Every read
path keys off `df.item_type[it:getType()]` (the ~110 top-level item types) via
`world.items.other[TYPE]`. Subtype discrimination is hand-coded in exactly two
places — `scripts/container_audit.lua:59` (`isFoodStorage()` to pull large pots
out of `TOOL`) and the brewing pipeline. That single design choice is the source
of both the `NEST_BOX` and the earlier `BOOTS` crashes, and it has wide blast
radius.

### Gap inventory

1. **Item subtypes are invisible — `TOOL` is the worst offender.** In
   `stock_report`, ~30 distinct objects collapse into one `TOOL` line: nest
   boxes, hives, jugs, large pots, wheelbarrows, minecarts, stepladders,
   bookcases, pedestals, display cases, altars, dice, pouches, scrolls, quires,
   and every written book. You cannot ask "how many jugs do I have," and
   `stockpile_locate TOOL` returns a meaningless blob. Same blindness hits
   `ARMOR`/`SHOES`/`HELM`/`WEAPON`/`TRAPCOMP`/`INSTRUMENT` subtypes.
2. **`stockpile_locate` has a latent crash, not a clean miss.**
   (`scripts/stockpile_locate.lua:25`) The guard
   `local vec = world.items.other[NAME]; if not vec then ...` assumes a bad key
   returns `nil`. It does not — DFHack **throws** on a nonexistent `items_other`
   field, so the `if not vec` net never fires. That is the raw
   `Cannot read field items_other.NEST_BOX: not found` traceback. Any
   caller-supplied type that is not a real `item_type` hard-errors.
3. **There is no building-investigation tool at all.** `shops_and_orders`
   counts workshops by type with no positions; `zones_intel` lists locations +
   civzone counts with no positions; `stockpile_locate` finds buildings only
   incidentally (as the tile-holder of an item). Nothing answers "where are my
   levers / pressure plates / floodgates / bridges / wells / cages / traps /
   altars / pedestals?" — though `workshops_of()`/`furnaces_of()`
   (`scripts/_prelude.lua:276`) already iterate `world.buildings.all` by type.
4. **Stockpile *configuration* is unreadable.** Nothing reads what a pile
   accepts, its links, or its bin/barrel caps. "Why won't my output store?" is
   usually a settings problem — a blind spot today.
5. **`container_audit` is shallow.** Binary full/empty
   (`contents_count > 0` = full), so a 10-capacity barrel holding 1 drink reads
   "full." No fill %, no positions, and bags (critical for sand/flour/gypsum)
   are lumped with chests/coffers under `BOX`.
6. **`stock` has no focused path and blows budgets.** `stock_query.lua` always
   scans `world.items.all`; it **timed out** in a recent briefing, and
   `stock_data` returned 129k chars (over the token cap). `acquirable_items`
   has a `focus` mode; `stock` does not.
7. **No single-item / item-by-id detail.** Cannot inspect one item's material,
   quality, wear, stack, container, or reserving job. `artifact_locate` does a
   slice of this for artifacts only.

### What is already good (use as the template)

- The two-axis classifier (`classify_item` / `stock_states` in
  `scripts/_prelude.lua`) is solid — keep routing everything through it.
- `isFoodStorage()` (`container_audit.lua:59`) proves the subtype pattern works;
  it just needs generalizing into a reusable `tool_subtype(it)` helper backed by
  `world.raws.itemdefs.tools`.
- The `pcall`-per-section degradation pattern is the right robustness model.
- `acquirable_items.lua:90` documents the key performance constraint:
  `findAtTile` per item poisons the single-threaded RPC. A building map must
  iterate `world.buildings.all` (cheap), never `findAtTile`.

## Summary+scatter vs per-instance — and why they are not in conflict

Today's locators **aggregate**: grouped counts plus a "scatter" (`by_z`
histogram + top-5 busiest tiles). That is right for bulk fungible stock (drinks,
stone, bars) but wrong for low-count, individually-meaningful things (buildings,
artifacts, a handful of nest boxes), where the exact coordinate is the whole
point. The tension — per-instance is precise but can token-explode; summary is
compact but imprecise — dissolves once a **local static-schema snapshot** lets
us resolve a filter *before* querying, so the result set is already small enough
to list per-instance. That is R0.

---

## R0 — Foundation: static raws snapshot + resolve-then-query + auto-tier

**Build first. Every item below depends on it.**

- **Snapshot.** A `dump_raws.lua` writes `data/raws_<worldid>.json` — the static
  schema: the `item_type` / `building_type` / `workshop_type` / `furnace_type`
  enums and the `itemdefs.{tools,weapons,armor,...}` subtype tables (id ↔
  index). Cache-keyed on world id (or a raws hash), with an auto-redump when the
  live world does not match the cache. Reuses the existing `data/` convention
  (`data/trade_history.json`).
- **Resolver (Python).** Maps a free-text filter (`"nest box"`,
  `"iron breastplate"`, `"BOOTS"`) → concrete `(item_type, subtype)` or a
  building predicate **before** any live call. A miss returns a clean
  *"no such type; did you mean SHOES?"* — this **eliminates the entire
  `items_other.X not found` crash class** (gaps #1, #2) at the source.
- **Auto-tier helper.** Shared rule: if matches ≤ ~50, per-instance list with
  exact coords; else fall back to summary+scatter. Plus a pagination cap
  (*"32 more — narrow the filter"*). This is what makes per-instance output
  token-safe.

*Effort: M · Risk: low · Fixes the root cause behind every gap.*

Static vs dynamic split that makes this work:

| | What it is | Changes when | Where it lives |
|---|---|---|---|
| **Static schema** | enum names + raws subtype defs | only at world-gen / mod load | snapshotted once, cached JSON |
| **Dynamic state** | actual items/buildings + positions, jobs, owners | every tick | queried live |

Caveats to build in: cache key = world id (or raws hash), invalidate on
mismatch with an auto-redump path; keep the pagination guard even with a tight
filter.

---

## Ranked build order

| # | Item | Fixes gap | Depends on | Effort | Risk |
|---|------|-----------|-----------|--------|------|
| **R1** | `stockpile_locate` hardening + subtype filter | #1, #2 | R0 | S | low |
| **R2** | `building_locate(type)` — new tool | #3 | R0 | M | low |
| **R3** | Focused `stock` path + subtype breakdown | #1, #6 | R0 | M | low |
| **R4** | `container_audit` depth (fill %, split bags, coords) | #5 | R0 | S–M | low |
| **R5** | Configuration reading (stockpile + building) | #4 | R2, R4 | L | **high** |
| **R6** | `item_detail(id)` — single-item inspector | #7 | R0 | S | med |

### R1 — `stockpile_locate` hardening + subtype filter
Wrap the `world.items.other[NAME]` lookup in `pcall` (the current `if not vec`
guard never fires — DFHack *throws* on a bad key). Accept a resolved
`(type, subtype)` so `stockpile_locate "nest box"` works and returns exact
coords via auto-tier. Smallest possible win once R0 exists; directly closes the
episode that started this.

### R2 — `building_locate(type)`
The generalized nest-box answer for **buildings**: levers, pressure plates,
floodgates, bridges, wells, cages, traps, altars, pedestals, plus
workshops/furnaces with position + built/idle/busy + current job. A thin
generalization of `workshops_of()`/`furnaces_of()` (`_prelude.lua:276`).
Iterates `world.buildings.all` (cheap) — **never** `findAtTile` per item (the
RPC-poisoning trap at `acquirable_items.lua:90`).

### R3 — focused `stock`
Add an `item_type`/subtype focus arg so `stock` can answer "just DRINK" without
scanning `world.items.all` — fixes the **timeout** and the 129k-char
`stock_data` budget blowout. Within a focused type, break out subtypes (jugs vs
nest boxes vs books under `TOOL`).

### R4 — `container_audit` depth
Replace binary full/empty with **capacity-aware fill %**; split bags
(sand/flour/gypsum-critical) out from chests/coffers under `BOX`; attach
positions so "this bin in stockpile #4 is full" is sayable.

### R5 — configuration reading
Stockpile accept-settings + links + bin/barrel caps; building owners/
assignments. This is the **"why won't it store / why won't it work"** layer —
and the **most version-fragile decode in DF**, so it is ranked last and built
**best-effort**: every field in its own `pcall`, degrade-to-note on a struct
shift, never break the report. Layered on R2/R4 so the locators are proven
before adding fragile depth.

### R6 — `item_detail(id)`
Inspect one item: exact material, quality, wear, stack, container, reserving
job, position. Generalizes the slice `artifact_locate` already does for
artifacts.

---

## Sequencing logic

R0 unblocks and de-risks everything (and kills the crash class). R1–R4 are all
low-risk, high-frequency wins that reuse existing machinery. R5 is isolated last
because it carries the version-fragility risk. R6 is independent and can slot in
anytime after R0.

## Appendix — nest box specifics (worked example)

- `ITEM_TOOL_NEST_BOX` is subtype **index 10** in `world.raws.itemdefs.tools`.
- Placed nest boxes set `item.flags.in_building`; `dfhack.items.getPosition()`
  returns nil for them — read `item.pos` directly.
- No dedicated `buildings_other` entry is created for a placed nest box (no
  `buildings_other.NESTBOX` / `.NEST_BOX`).
- The fort inspected during this design had **0** nest boxes (none placed, none
  in stock).
- The ad-hoc query pattern used to discover the above is recorded in `CLAUDE.md`
  under "Ad-hoc DFHack queries (no MCP tool yet)".
