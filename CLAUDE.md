# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Python MCP server (`crystal-ball`) that connects to a locally-running Dwarf Fortress + DFHack instance over the DFHack RPC socket (`127.0.0.1:5000`) and reports the status of — and diagnoses blockers in — every major fortress industry. Read-only by design except for a small, gated set of write tools (see below). Verified against DFHack 53.14-r2 / DF 53.14 **Steam version** (DF 50+, premium graphical release). Classic/legacy DF is not supported.

The real code lives entirely under `agent/`. **`reference/dfhack-mcp-source/` is a vendored example project — no code from it is used here.**

## Commands

Run from `agent/` using the bundled venv (Python 3.13). There is no build, lint, or test-runner step; the verification path is the selftest.

```
# MCP server (stdio transport — how Claude Code/Desktop launches it)
.venv\Scripts\python.exe mcp_server.py

# Selftest: calls ~36 tools directly, no MCP client needed. Use this to verify
# changes against a live fort.
.venv\Scripts\python.exe mcp_server.py --selftest

# CLI reports (read-only)
.venv\Scripts\python.exe cli.py briefing     # batched morning roll-up
.venv\Scripts\python.exe cli.py              # brewing (default)
.venv\Scripts\python.exe cli.py stock        # broad inventory (cached baseline)
.venv\Scripts\python.exe cli.py stock --rebuild   # force a full live re-scan
.venv\Scripts\python.exe cli.py stock DRINK  # one type, live (warms the baseline)
.venv\Scripts\python.exe cli.py <report> [--json]
#   reports: briefing brewing stock acquire containers shops diagnose textiles
#            textiles-diag roster mood zones hotkeys announcements
#            dwarf <sel> labor <name> artifact <sel> deity <name> faith <sel>

# CLI write ("act") subcommands — default is advise (read-only); a write needs
# BOTH --apply and --confirm. --preview shows the exact plan without writing.
.venv\Scripts\python.exe cli.py queue-order MakeCrafts 20 stone --apply --confirm
.venv\Scripts\python.exe cli.py fix-idle --preview
#   also: stock-target, containers-fix, boost-mood, hospital-supplies, set-hotkey
```

Runtime deps are pinned in `agent/requirements.txt`: `protobuf` (RPC bindings, CLI + server) and `mcp` (server only). DF + DFHack must be running with a fort loaded.

## Architecture

```
dfhack_rpc/client.py          # TCP transport: handshake, framing, RunCommand
scripts/_prelude.lua          # Shared Lua helpers prepended to every READ query
scripts/<industry>_intel.lua  # One status query per industry
scripts/diagnose_<industry>.lua
scripts/actions/_prelude.lua  # Shared helpers prepended to every WRITE script
scripts/actions/*.lua         # create_order, set_hospital_supplies, set_hotkey
intel.py    # run_intel(): prepend read prelude, exec script, parse JSON
            # shared_connection(): reuse one socket across a batch of reads
actions.py  # run_action(): same pattern, for mutation scripts
resolve.py  # free-text -> (item_type, subtype)/(building_type, subtype), backed
            # by a cached raws snapshot; resolve_item/resolve_building, tier_mode
stockcache.py  # broad-stock baseline: on-disk data/stock_<world_id>.json, served
            # cheap + per-type-refreshed; get_broad/full_rebuild/patch_type
scripts/stock_probe.lua  # cheap freshness probe: clock + per-type vector lengths
scripts/dump_raws.lua  # one-time static-schema dump -> data/raws_<world_id>.json
briefing.py # fort_briefing: batched morning roll-up over one shared_connection
<industry>.py  # Per-industry fetch_*() + format_*() pairs (brewery, food, ...)
pipelines.py   # stock / acquirable / containers / shops / *_locate / *_config /
               # item_detail fetch+format
mutations.py   # The write tools, with the advise/preview/apply gate
mcp_server.py  # FastMCP server wiring every tool
cli.py         # CLI front-end (read reports + act subcommands)
```

**Read data flow:** `mcp_server.py` → `<module>.fetch_*()` → `intel.run_intel("foo_intel.lua", args)` → prepend `_prelude.lua` → `DFHackClient.run_command("lua", [lua, *args])` → parse JSON → `format_*()` → text. The write path is identical but goes through `actions.run_action()` → `scripts/actions/*.lua`.

**Subtype/building resolution (`resolve.py`).** The item model is type-aware but subtype-blind: `world.items.other[TYPE]` keys off the ~110 top-level `df.item_type`s, so the ~30 things sharing `TOOL` (nest box, jug, wheelbarrow, book, altar…) collapse together, and a bad type name *throws* (the old NEST_BOX/BOOTS crash). `resolve.py` fixes this by mapping free text → a concrete `(item_type, subtype)` (`resolve_item`) or `(building_type, subtype)` (`resolve_building`) **before** the live query, against a one-time static-schema snapshot. `scripts/dump_raws.lua` dumps the enums + `itemdefs.{tools,weapons,armor,…}` tables to `data/raws_<world_id>.json` (keyed on `cur_savegame.world_header.id1`, auto-redumped on world change; consumed by Python, never returned to the model — so its size is irrelevant). The locate/stock/`item_detail` fetchers resolve first, pass the subtype to the Lua as an arg, and `item_subtype(it)` (prelude, generalizes `isFoodStorage`) filters live. An unknown name returns a `did-you-mean` suggestion, never a crash. `resolve.tier_mode(count)` drives the locate formatters' auto-tier: per-instance with exact coords when few, summary+scatter when many.

**Stock baseline cache (`stockcache.py`).** A *broad* stock query (no `item_type`) would otherwise pay a full ~29k-item / ~10s `world.items.all` scan every time. Instead it is served from an on-disk per-world baseline `data/stock_<world_id>.json` (the dynamic sibling of the static raws cache), refreshed **per type only when stale**. A cheap probe (`scripts/stock_probe.lua`: in-game clock `cur_year`/`cur_year_tick` + each type's loose-vector length `#world.items.other[TYPE]`, milliseconds) drives the decision. Types are **self-classified at rebuild** by comparing the loose-vector length to the true `items.all` count: `"vector"` (≥90% captured — drink/food/plants; cheap focused refresh; TTL **1 game-week**) vs `"heavy"` (badly undercounted because stock lives in containers/inventories — BOOK 17 vs 12355, worn armor; refreshed only by a full rebuild; TTL **1 season**). `get_broad()` decides: missing/world-changed baseline or a never-seen type → full rebuild; a heavy type past its season → full rebuild; else focused-refresh just the vector types past a week or whose vector length **drifted** (compared against the stored raw `vector_len`, *not* `item_count`, so carried items don't masquerade as drift); else serve untouched. A *targeted* read (`fetch_stock("DRINK")`) is always live and **warms** the baseline via `patch_type()` — but **only for `"vector"`-class types**: a focused scan reads `world.items.other[TYPE]`, which undercounts heavy types, so warming a heavy type from a targeted read would corrupt the baseline's true count (this guard is load-bearing — without it a `stock_report item_type=TOOL` drops the cached TOOL count from 9242 to 26). The full rebuild itself is paginated in `pipelines._fetch_stock_full` (index-range chunks of `_STOCK_CHUNK=6000` over one `shared_connection`) so each RPC stays under the 5s socket timeout. **Disk-only, no in-memory tier** (the file read is sub-ms; disk is the only thing the per-tab stdio server processes share, giving free multi-tab coherence), written atomically (temp + `os.replace`). When answering a broad stock question prefer the cached `stock_report`; reach for `stock_report item_type=X` (live) when freshness matters, or `refresh=True` / `cli.py stock --rebuild` to force a full rebuild. **Counterintuitive asymmetry:** for a *heavy* type the broad cached report holds the *truer* count (from the full `items.all` scan) while a targeted query returns only the loose-vector count — the reverse of the usual "targeted is fresher/better".

**`scripts/_prelude.lua` is the single source of truth** for material decoding and item-state classification. Every "available"/"on hand" count routes through `classify_item()` (via `is_available()` or `stock_states()`). Fix a counting bug there and it's fixed across every industry.

### `classify_item()` states

```
reachable / in_container  → AVAILABLE (usable by a job now)
in_transit                → being hauled in (owned, not yet usable)
forbidden / dumped / claimed_job / carried / melt  → owned but locked
uncollected_web / loose_unreachable / trade        → NOT owned yet
installed / rotten        → inert (counted in total, never stock)
dead                      → excluded
```

When answering "how much X do I have", report `on_hand` (= available + in_transit + owned_unavailable + inert) or `available` — **never** `total`. `total` folds in unowned items (silk still in webs, caravan trade goods, unreachable items). The spider-silk miscount is the bug this split fixed.

### Tool naming convention

Every industry exposes a quartet: `<name>_report` (text), `<name>_data` (JSON), `diagnose_<name>` (ranked blockers + facts), `diagnose_<name>_data` (JSON). Fort-wide and dwarf tools follow the same `_report`/`_data` pattern.

### Write ("act") tools — `mutations.py`

There are **seven** write tools: `queue_work_order`, `auto_stock_target`, `fix_idle`, `manage_containers`, `boost_mood`, `manage_hospital_supplies` (wraps `set_hospital_supplies`), and `set_hotkey`. Every one is mode-gated:

- `mode='advise'` (default) — read-only; explains the plan + manual click-path.
- `mode='preview'` — read-only; shows the exact orders/changes.
- `mode='apply'` **with `confirm=True`** — the only path that writes.

All writes funnel through `actions.run_action()` into an audited `scripts/actions/*.lua` script that validates every enum (job_type / reaction / material / item_type) *before* mutating and `pcall`-wraps each write, returning `{ok, created[], errors[]}`. Only **reversible** actions are written: manager orders (cancel in-game), hospital supply maximums, hotkey slots. Anything structural — designating a tavern/temple/library/hospital zone, placing a workshop — is returned as advice text only.

**Do not add new write tools without explicit instruction** (stated in `mcp_server.py`'s module docstring).

## DF/DFHack quirks (grounded in this codebase)

- **Brewing is a `CustomReaction`, not a `BrewDrink` order.** The code queues drinks with `job="CustomReaction"`, `reaction_name="BREW_DRINK_FROM_PLANT"` (`mutations.py` `REACTION_BREW` / `_STOCK_TARGET_JOBS`).
- **Bin job is `ConstructBin`** (`mutations.py` `JOB_BIN`), not `MakeBin`. Blocks/mechanisms/crafts/weave are `ConstructBlocks` / `ConstructMechanisms` / `MakeCrafts` / `WeaveCloth`.
- **`material_category` is an organic-only bitfield** (wood/cloth/silk/yarn/leather/bone/shell/plant). Stone/metal/glass have no flag — generic stone is the raw `(mat_type=0, mat_index=-1)` pair; a concrete name (e.g. `MICROCLINE`) goes via `dfhack.matinfo.find`. `validate_order` probes the bitfield live before trusting a category name.
- **Hospitals are locations, not civzones** — `abstract_building_hospitalst` on `getCurrentSite().buildings` (`df.civzone_type` has no Hospital entry). Supply limits live in `contents.desired_*` in raw dimension units; the tools convert to/from whole items.
- **`world.items.other[TYPE]` is an incomplete "loose items" index, not all items of that type.** For most goods it ≈ the true count (drink/food/plants/bars), but for container-heavy types it badly undercounts: books in bookcases and tools in stockpiles/inventories mostly aren't in it (BOOK vector 17 vs 12357 in `items.all`, TOOL 26 vs 9242). Only `world.items.all` is the complete source, so *broad "every good"* counts must come from an `items.all` scan (paginated + cached — see stockcache above); a focused `world.items.other[TYPE]` scan is fast but blind to the container-held majority for those types. This split is why `stockcache` classifies types `vector` vs `heavy`.
- **Some goods split across two `df.item_type` slots by processing stage** — `FISH` (49) vs `FISH_RAW` (50), `PLANT` (54) vs `PLANT_GROWTH` (56). Counting only one silently drops the other, so the briefing's `_KEY_STOCKS` (`briefing.py`) lists both stages as their own headline rows (same undercount class as the spider-silk `total` bug).
- **`in_inventory` is set for BOTH container-stored items and unit-carried items.** Use `dfhack.items.getHolderUnit()` to tell them apart — never treat `in_inventory` alone as an availability signal.
- **`item.walkable_id` is stale** (lazily refreshed). Always read reachability live via `dfhack.maps.getWalkableGroup(item.pos)`.
- **Walk-group plurality rule** — the fort's reference walk group is the one held by the *most* citizens, not any citizen. A dwarf stranded in the caverns must not bless unreachable cavern items as available.
- **CP437 text** — DFHack RPC output is decoded as CP437 (`client.py`) so special glyphs in dwarf names survive.
- **DF v50+ labor model** — per-unit labor toggles were largely replaced by work details; `unit_labor` entries are reachable only by numeric index, not `pairs()`. `labor_check()` reflects this.
- **Steam UI, not classic DF UI** — the in-game interface is the Steam/premium graphical version. When giving UI navigation advice, use Steam UI paths (e.g., **Y** → Labor → Kitchen to toggle cookable ingredients; the classic `z` → Status → Kitchen path does not exist). Do not cite classic ASCII keybindings for in-game actions.

## Subtype & building investigation (use the tools, not ad-hoc Lua)

The investigation gaps that used to need ad-hoc one-liners are now MCP tools (see
`resolve.py` above and `docs/investigation-roadmap.md`):

- **Find a specific item** (nest box, jug, wheelbarrow, altar, an armor piece) →
  `stockpile_locate "<free text>"` — resolves the subtype, returns exact coords
  when few. **Find buildings** (levers, floodgates, wells, a workshop) →
  `building_locate "<free text>"`. **Itemize a TOOL/ARMOR/WEAPON type by subtype**
  → `stock_report item_type=TOOL` (but note: a focused query sees only the loose
  `world.items.other[TYPE]` vector, so for container-heavy types its *total* is an
  undercount — the broad cached `stock_report` has the true count). **Inspect one item** → `item_detail <id>`
  (ids come from `stockpile_locate_data` `items[].id`). **Pile accept-config /
  room ownership** → `stockpile_config` / `building_config`.
- Nest-box specifics (still true, now handled by the tools): `ITEM_TOOL_NEST_BOX`
  is subtype 10 in `world.raws.itemdefs.tools`; placed ones set `flags.in_building`
  and `getPosition()` returns nil (use `item.pos`); there is no
  `items_other.NEST_BOX` / `buildings_other.NESTBOX` — the resolver handles this.

**For a genuinely new gap** (a struct not yet surfaced by any tool), use a direct
`DFHackClient.run_command('lua', [lua])` one-liner from `agent/` — output goes via
`print()`, not `return`:
```python
# run from agent/
import sys; sys.path.insert(0, '.')
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
from dfhack_rpc.client import DFHackClient
with DFHackClient() as c:
    print(c.run_command('lua', [r"""<lua here>"""]))
```
Useful primitives: enums enumerate by numeric index `E._first_item.._last_item`
(not `pairs()`); building type/subtype/pos/jobs via `b:getType()` / `b:getSubtype()`
/ `b.x1,y1,z` / `#b.jobs`; build stage via `b:getBuildStage()` vs
`getMaxBuildStage()`; container fill via summed `ci:getVolume()` over
`getCapacity()`; a BOX with material flag `ITEMS_HARD` is a chest, without it a bag.

## Safety invariants (do not break)

- `DFHackClient` refuses any host other than `127.0.0.1`/`localhost`/`::1`.
- `intel.run_intel()` and `actions.run_action()` only execute the fixed, bundled files in `scripts/` and `scripts/actions/`. **No Lua string from a caller or tool argument is ever executed** — script args are forwarded as Lua varargs and used as data (a selector, a labor name, a JSON order spec) only.
- The MCP server uses stdio transport and binds no network port; the only outbound connection is the loopback DFHack socket.
- Every Lua read script wraps each section in `pcall`, so a struct-layout change in a future DF version degrades one section to an error note instead of breaking the whole report.
