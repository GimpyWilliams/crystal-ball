# df_hack agent — Dwarf Fortress management intel

> **Steam version only.** This project targets the **DF 50+ Steam/itch.io release**
> (premium UI, graphical tileset). It will not work correctly with classic/legacy DF.

A small, auditable client that connects to a **locally running** Dwarf Fortress
+ DFHack instance over DFHack's RPC socket and reports the status of — and
diagnoses blockers in — every major fortress industry and subsystem.

**Read-mostly.** Every status/diagnosis report is strictly read-only. A small,
clearly delimited set of "act" tools can change game state, but only in
`mode='apply'` with `confirm=True`, and only via **reversible** writes (creating
manager orders, setting hospital-supply maximums, or setting an F-key bookmark).
In their default mode they are read-only (advise/preview). See *Write ("act")
tools* and *Safety model* below.

The MCP server is `crystal-ball`. (It began life as a brewing-only helper,
`dwarf-fortress-brewery`/`dwarf-fortress-steward`; brewing is now just one of
many pipelines it sees into.)

Built from scratch; uses **no code** from the `reference/` example projects.
Verified against DFHack 53.14-r2 / DF 53.14 (Steam version).

## Layout

```
dfhack_rpc/
  client.py            # minimal RPC transport (handshake, framing, RunCommand)
  CoreProtocol_pb2.py  # generated protobuf bindings (from proto/CoreProtocol.proto)
proto/CoreProtocol.proto   # vendored from the official DFHack repo
scripts/                   # READ queries: vetted read-only Lua, the only reads ever sent
  _prelude.lua             #   shared read helpers prepended to every query (see below)
  <industry>_intel.lua     #   one status query per industry
  diagnose_<industry>.lua  #   one root-cause query per industry
  stock_query.lua          #   generic stock inventory (available vs total, by state; paginated full scan)
  stock_probe.lua          #   cheap freshness probe for the stock baseline cache
  acquirable_items.lua     #   inverse of stock: recoverable items, bucketed by why
  container_audit.lua      #   barrel/pot/bin/box storage audit
  shops_and_orders.lua     #   workshops + manager order queue (material-aware)
  dwarf_roster.lua / dwarf_detail.lua / labor_coverage.lua / announcements.lua
  mood_intel.lua / zones_intel.lua / hotkeys_intel.lua / caravan_intel.lua /
    world_agreements_intel.lua / artifact_locator.lua / deity_detail.lua /
    citizen_faith.lua                # more read queries (moods, zones, legends, ...)
  actions/                 # WRITE scripts: the only mutations ever sent
    _prelude.lua           #   shared write helpers (validate-before-write, pcall)
    create_order.lua       #   create one or more manager orders
    set_hospital_supplies.lua / set_hotkey.lua
intel.py        # shared read helper: prepend _prelude, run a vetted script, parse JSON
                #   also shared_connection(): reuse ONE socket across a batch of reads
actions.py      # shared write helper: same pattern for scripts/actions/ mutations
mutations.py    # the write ("act") features behind the advise/preview/apply gate
reports.py      # shared plain-text formatters (diagnosis renderer, error notes)
brewery.py / food.py / textiles.py / metalworks.py / construction.py /
  medical.py / justice.py   # per-industry fetch + format
pipelines.py    # stock / container / shops / acquirable fetch + format
stockcache.py   # on-disk per-world stock baseline: broad reads served cheap, refreshed per-type
diagnostics.py  # brewing diagnosis fetch + format
dwarves.py      # roster / dwarf detail / labor coverage fetch + format
mood.py / zones.py / hotkeys.py / trade.py / agreements.py / announcements.py /
  legends.py    # more per-subsystem fetch + format (moods, zones, caravan, ...)
briefing.py     # batched "morning briefing" over one shared connection
cli.py          # plain-text / --json command-line reports + act subcommands
mcp_server.py   # MCP server (stdio) exposing every report, diagnosis + act tool
```

`intel.run_intel()` prepends `scripts/_prelude.lua` to each query, so the shared
helpers (`section`, `add`, `matname`, `matdesc`, `classify_item`, `is_available`,
`stock_states`, `labor_check`, `furnaces_of`, `workshops_of`, `finish`, and the
`world`/`report` globals) live in **one** audited place. `classify_item` is the
single source of truth for item state — it resolves each item to exactly one of
reachable / in_container / in_transit / loose / loose_unreachable / uncollected_web
/ carried / claimed_job / forbidden / dumped / installed / dead, adding
reachability (a live walk-group compare vs the fort's plurality group), the
uncollected-web flag, and the hauling-vs-real-job distinction that the old
flags-only check missed. `is_available` (available now) and `stock_states`
(available / in_transit / acquirable / inert split) are thin wrappers over it, so
every "free"/"on hand" count is reachability-aware and consistent. Some scripts
also take an argument (a dwarf id/name, a
labor name); it is forwarded as Lua `...` and used ONLY as a lookup/filter value
— never executed — so the "only fixed audited files run" invariant still holds.

DF stores text in CP437, so the RPC client decodes captured text as CP437.
In DF v50+ per-unit labor toggles were largely replaced by work details, and
`unit_labor` entries are reachable only by numeric index, not `pairs()`.

## Tools / reports

Every industry exposes a matching set: `<name>_report` (text), `<name>_data`
(JSON), `diagnose_<name>` (ranked blockers), `diagnose_<name>_data` (JSON).

| Industry tool family | What it answers |
|----------------------|-----------------|
| `brewing` | drinks, stills, brewable plants, brew orders |
| `cooking` | meals, cookable ingredients + variety, kitchens |
| `farming` | plots, season crop assignment, seeds per crop |
| `fishing` | edible/raw fish, fisheries, catch + clean labor |
| `butchery` | slaughter queue, corpses, butcher shops, tanning |
| `textiles` | thread/cloth, clothing wear (tattered signal), looms/clothiers |
| `metal` | ore, bars, smelters/forges, fuel gate |
| `fuel` | charcoal/coke, logs, wood furnaces, magma alternative |
| `construction` | masonry / carpentry / glass / mechanisms in one view |
| `medical` | hospital, wounded, caregiver coverage, supplies |
| `justice` | sheriff / captain of the guard, crime caseload |

Fort-wide and dwarf tools (also `_report` + `_data`, and CLI where noted):

| Tool | CLI | What it answers |
|------|-----|-----------------|
| `fort_briefing` | `cli.py briefing` | batched "morning briefing": citizen/stress summary, strange moods (insanity-risk flags), hospital, workshop idle/busy + active orders, key survival stocks, and a cross-industry roll-up of flagged blockers — all over ONE shared connection |
| `stock_*` | `cli.py stock` | items on hand by type + material; **available** (reachable & usable) vs total, with the remainder split into in-transit / acquirable / inert. Broad (no `item_type`) is served from an on-disk baseline cache (`stockcache.py`), refreshed per-type; pass `item_type` for a live single type, or `refresh=True` / `--rebuild` to force a full re-scan |
| `acquirable_items` | `cli.py acquire [TYPE]` | the inverse of stock: items NOT freely available but recoverable — uncollected webs, carried/stranded cargo, loose or cavern-stuck stock, claimed/forbidden/dumped/at-depot — each with a "how to get it" hint |
| `container_*` | `cli.py containers` | barrels/pots/bins/boxes empty vs full |
| `shops_and_orders_*` | `cli.py shops` | workshops idle/busy + manager order queue (with material/condition labels) |
| `stockpile_locate_*` | — | which stockpile(s) hold a given item type |
| `dwarf_roster_*` | `cli.py roster` | all citizens: job, stress, unmet needs, wounds, mood |
| `dwarf_detail_*` | `cli.py dwarf <id\|name>` | one dwarf: labors, skills, needs, thoughts, health |
| `labor_coverage_*` | `cli.py labor <NAME>` | who can do a labor (idle/busy) + work details |
| `mood_report*` | `cli.py mood` | strange-mood scan: who's moody + what their job still demands vs stock |
| `zones_*` | `cli.py zones` | fort locations (taverns/temples/hospital/library) + civzone counts |
| `hotkeys_*` | `cli.py hotkeys` | the 16 F-key map bookmarks (name + coordinates) |
| `announcements_*` | `cli.py announcements` | recent game announcements / alerts |
| `caravan_*` | — | active caravan(s): trade state, requested goods, depot goods |
| `trade_history_*` | — | persistent log of past caravan arrivals (local JSON, no live game) |
| `agreements_*` | — | diplomacy entities + world agreements (version-probed) |
| `artifact_locate_*` | `cli.py artifact <id\|name>` | locate one artifact + its current spot (held/stored/built/x,y,z) |
| `deity_detail_*` | `cli.py deity <name>` | a deity's spheres + which fort temple is dedicated to it |
| `citizen_faith_*` | `cli.py faith <id\|name>` | a dwarf's worshipped deities + the temple to honor each |

## Write ("act") tools

These are the **only** tools that can change game state, and only in
`mode='apply'` with `confirm=True`. Their default mode is read-only:
`mode='advise'` explains what it would do + the manual click-path; `mode='preview'`
shows the exact orders/changes; `mode='apply'`+`confirm` writes. All writes are
reversible. CLI equivalents default to advise; `--preview` previews; a write
needs both `--apply` and `--confirm`.

| Tool | CLI | What it writes (apply+confirm only) |
|------|-----|-------------------------------------|
| `queue_work_order` | `cli.py queue-order <job> <amt> [material]` | one manager order |
| `auto_stock_target` | `cli.py stock-target <item> <target> [job]` | a conditional repeat order (keep ≥ target) |
| `fix_idle` | `cli.py fix-idle` | stone-craft / block / mechanism / weave orders matched to idle shops |
| `manage_containers` | `cli.py containers-fix` | pot/bin production when storage is full |
| `boost_mood` | `cli.py boost-mood` | a top-up brew order (zone advice is text-only) |
| `manage_hospital_supplies` | `cli.py hospital-supplies <field> <max> ...` | an existing hospital's desired-supply maximums |
| `set_hotkey` | `cli.py set-hotkey <id> <name> <x> <y> <z>` | one F-key map bookmark |

The CLI (`cli.py`) wires all the fort-wide/dwarf reports plus the act
subcommands; the per-industry status + diagnosis tools are exposed via the MCP
server (and `mcp_server.py --selftest` exercises every tool).

## Safety model

- The client refuses any host other than loopback (`127.0.0.1`/`localhost`/`::1`).
- The only DFHack commands issued are the bundled, audited Lua files — read
  queries from `scripts/*.lua` and mutations from `scripts/actions/*.lua` (each
  with its `_prelude.lua`). **No command string is ever taken from a caller or
  tool argument**; script arguments are forwarded as Lua varargs and used as
  data (a selector, a labor name, a JSON order spec) only.
- Read scripts only read `df.global.world` (and, for diagnosis, work details);
  they never assign to game structures.
- Writes are gated three ways: a feature writes only in `mode='apply'` **with**
  `confirm=True`, re-derives its plan from live state on every apply, and goes
  through an audited `scripts/actions/*.lua` that validates every enum
  (job_type / reaction / material / item_type) **before** mutating and
  `pcall`-wraps each write. Only reversible actions are written (manager orders,
  hospital-supply maximums, hotkey slots). Structural changes — designating a
  tavern/temple/library/hospital zone, placing a workshop — are returned as
  advice text only, never written. No new write tools are added without explicit
  instruction.
- The MCP server uses stdio transport — it binds **no network port**. The only
  outbound connection is the loopback DFHack RPC socket.

## Requirements

- **Dwarf Fortress Steam version (DF 50+)** + DFHack running with a fort loaded
  (DFHack listens on 127.0.0.1:5000). Classic/legacy DF is not supported.
- Python 3.13, venv at `agent/.venv`.
- Runtime deps: `protobuf` (CLI + server) and `mcp` (server only). Pinned in
  `requirements.txt`: `.venv\Scripts\python.exe -m pip install -r requirements.txt`.

## Usage

Plain CLI (no MCP client needed):

```
.venv\Scripts\python.exe cli.py briefing      # batched morning roll-up
.venv\Scripts\python.exe cli.py              # brewing report (default)
.venv\Scripts\python.exe cli.py stock         # broad inventory (cached baseline)
.venv\Scripts\python.exe cli.py stock --rebuild  # force a full live re-scan
.venv\Scripts\python.exe cli.py stock DRINK   # one type, live (warms the baseline)
.venv\Scripts\python.exe cli.py containers    # storage audit
.venv\Scripts\python.exe cli.py shops         # workshops + order queue
.venv\Scripts\python.exe cli.py diagnose      # why isn't beer being made?
.venv\Scripts\python.exe cli.py roster        # all citizens at a glance
.venv\Scripts\python.exe cli.py dwarf Urist    # profile dwarves matching "Urist"
.venv\Scripts\python.exe cli.py labor BREWER   # who can brew (idle/busy)
.venv\Scripts\python.exe cli.py stock --json  # any report as raw JSON

# Write ("act") subcommands -- default is advise (read-only); a write needs BOTH
# --apply and --confirm. --preview shows the exact plan without writing.
.venv\Scripts\python.exe cli.py fix-idle                  # advise: what it would queue
.venv\Scripts\python.exe cli.py queue-order MakeCrafts 20 stone --apply --confirm
```

MCP server selftest (calls every tool directly, no client):

```
.venv\Scripts\python.exe mcp_server.py --selftest
```

### Register the MCP server

**Claude Code (CLI):**

```
claude mcp add crystal-ball -- ^
  C:\path\to\df_hack\agent\.venv\Scripts\python.exe ^
  C:\path\to\df_hack\agent\mcp_server.py
```

**Claude Desktop** — add to `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "crystal-ball": {
      "command": "C:\\path\\to\\df_hack\\agent\\.venv\\Scripts\\python.exe",
      "args": ["C:\\path\\to\\df_hack\\agent\\mcp_server.py"]
    }
  }
}
```

Then just ask, e.g. *"Why aren't my dwarves cooking?"* or *"What's blocking my
metal industry?"* — the assistant calls the matching `diagnose_*` tool. Every
tool has a `*_data` twin that returns the same information as structured JSON.

### `/df-report` slash command

`commands/df-report.md` (repo root) is a Claude Code slash command that batches
the fort-wide tools into one morning briefing. Copy it into your own
`.claude/commands/` (project) or `~/.claude/commands/` (global) directory, then
run `/df-report` after loading a save.
