# Deep metal industry and drop chutes

A plan for moving ore from the mining levels down to the smelting and forging
hall on z11, and for growing that system as mining spreads. Written at year
259, tick about 353,000. Coordinates are map tiles (x, y, z).

Every layout fact here comes from tiles that are revealed in game: dug areas,
buildings and stockpiles. Nothing was planned from hidden rock or hidden veins.
Where a plan has to dig into unrevealed rock (a chute through cavern 3, say),
it says so and says what to do if the dig opens into something.

## Fix first: stairs open onto magma

On z10, 9 up/down stairs sit directly over full-depth magma (7/7) on z9, at
x112–115, y66–69. They are left from the 34 stair designations over the magma
pool. Some were dug before the rest were removed.

Magma does not rise up stairs by itself. The risk is creatures from the magma
sea climbing up them, through the z10 pocket and up the down-stairs on the north
side of the z11 hall (x102–116, y63–71).

What to do: remove the z11 down-stairs above that pocket, which seals z10 off
from the hall. A `run_blueprint` dig phase can mark those z11 tiles with
quickfort's remove-stairs designation, after a dry run. Until then, keep
workers out of the north end of the z11 hall.

## Goals

1. Haul as little as possible up and down the 107 levels between the mines and
   the upper fort.
2. Smelt and forge where the ore ends up, beside the magma, so it needs no fuel.
3. Send only finished goods upward, a bin per trip.
4. Make every new mining area a small add-on, not a new project.

## What exists now

### The z11 hall

| Part | Tiles | Notes |
|---|---|---|
| Hall floor | x84–118, y92–108 | Its ceiling at z12 is open, so it is two levels tall. z10 beneath it is the magma lake that feeds the workshops. |
| 4 magma forges | x103–108, y92–97 | |
| 8 magma smelters | x103–114, y103–108 | |
| Main stair shaft | x94–96, y102–104 | Runs from the top of the fort down to z10. |
| Second stair shaft | x92–94, y87–89 | Runs z7–13. |
| Ramp | (98,100) | |
| North hall | x91–124, y60–84 | Joined by a corridor at x92–102, y84–91. Holds the magma-stair hazard above. |

### Stockpiles on z11

| # | Name | Tiles | Settings | Role |
|---|---|---|---|---|
| 73 | Q11 | (100,104) | Quantum (links only, no containers). Ore, economic stone, rough gems; no plain stone. | Landing tile under the planned chute. The smelters feed from it. |
| 77 | BAR-Deep | x110–118, y92–100 | Metal bars only, no blocks; 81 bins | Smelter output and forge input. |
| 75 | FG-Deep | x97–102, y92–97 | All finished goods; 36 bins | Forge output. Gives to TREAS-Gem-Set, TREAS-Silver, TREAS-Gold, TREAS-Steel-Copper and TREAS-Artifact on z111. |
| 76 | BIN-Deep | x116–118, y104–106 | Furniture: bins only | Spare bins, so binning never stalls. |

The blueprint `deep_metal` places these. The stockpile tool then sets the
filters the presets miss.

### On z20 (the G2 pilot)

- **Track:** x100, y85–103.
- **Stop 1** at (100,85) takes from G2-Feed (#70 and #71, y85 lane) and leaves
  when full.
- **Stop 2** at (100,103) dumps south onto Q20 (#69) at (100,104) and leaves when
  empty.
- **Q20** currently gives to ORE-Metal-Smelt, GEM-Rough and STONE-Marble-Mine,
  all upstairs. That changes once the chute exists.

## The flow

```
mining level (z20, later z21+)
  ore lands in the lanes
  -> feeder pile beside a load stop
  -> cart on flat track
  -> dump stop over a chute
        |  ore falls down the chute (no cart changes level)
        v
z11  Q11 (landing) -> smelters -> BAR-Deep -> forges -> FG-Deep
        |
        v  haulers carry full bins up the stairs
z111 TREAS-* vault piles
```

No cart ever goes uphill, so no lift, rollers or mechanical power are needed.

## Drop chutes: design rules

A drop chute is a 1×1 column of open space. A cart dumps ore into the top and
it falls to the floor at the bottom.

1. **Never dig into the z11 floor.** The magma lake is right under it. A
   chute stops at z12, which is already open air in the hall, and the ore lands
   on the z11 floor.
2. **Dig from the top down.** Channel the column level by level, starting at
   the dump tile. Miners always stand above the hole they are digging.
3. **Expect cavern 3 between z15 and z19.** The column passes through those
   levels in rock that is not revealed yet. If a level opens into cavern space,
   stop and wall that level around the column before going lower. Otherwise the
   chute becomes a path from the cavern into the mining level and the hall.
4. **Falling ore hurts.** Put each landing tile off the main walkways, and mark
   it as restricted traffic. Smelter workers still step on it to fetch ore, so
   keep it to a single tile beside the smelters.
5. **Only ore travels.** Every load stop takes from a feeder pile set to ore,
   economic stone and rough gems, so plain stone never rides or falls.
6. **One landing per chute.** Each chute has its own quantum pile at the
   bottom. The smelters take from all of them through workshop links.

### Chute C1: z20 to z11 at (100,104)

| Step | What | Notes |
|---|---|---|
| 1 | Remove Q20 on z20 | Its tile becomes the top of the chute. |
| 2 | Channel (100,104) on z20 down through z13 | Top down; checks at z15–19 for cavern. z14 is inside the z14 hall, so a hole appears in that hall's floor. |
| 3 | Leave z12 as it is | Already open air. |
| 4 | Keep G2 stop 2 as it is | It already dumps south onto (100,104). |
| 5 | Q11 catches the ore | It's at (100,104,11), placed. |

Checks after digging:
- Drop one boulder and see it arrive on Q11.
- Confirm no level of the column opened into cavern space.

Watch out: (100,104) on z11 is 4 tiles from where the main shaft opens into the
hall. If dwarves crowd that tile, move C1 a few tiles east. G2 then needs a
new dump stop that faces the new column.

## Adding mining areas

Each new strip-mine area adds:

1. **A feeder pile** (or two) placed where the area's ore lands. It accepts ore,
   economic stone and rough gems only, with no plain stone.
2. **A flat cart line** on the same level, from a load stop beside the feeder to
   a dump stop beside a chute.
3. **A route** with "leave when full" at the load stop and "leave when empty"
   at the dump stop, plus a cart. There are 5 spare carts.

Which chute it uses:

- **Mining above z20, near x100 y104:** extend C1 upward. Channel the same
  column through the new level and put that level's dump stop beside it.
  Several levels can share one chute, with each level's stop on a different
  side of the column.
- **Mining on z20 or nearby, far from C1:** run a longer flat line to C1, or
  dig a second chute.
- **A second chute (C2):** pick a column that ends over open z11 floor (or
  z12 air) away from walkways and the shaft, and that does not cross the north
  hall's stair pocket. The z11 hall's east side (x115–118) and west side
  (x84–92) are the obvious landing areas. Each new chute gets its own Q pile
  and its own smelter links.

Each new area is one blueprint: feeder, track, stops, route conditions and
cart. It follows the `g2_pilot` pattern.

## Carving space so dwarves can work

The hall has room for the current piles (about 300 free floor tiles west of the
workshops), so no extra digging is needed yet. When it is, follow these rules.

### Access
- The main shaft (x94–96, y102–104) is the hall's front door. Keep the 3 tiles
  around its opening clear of stockpiles and landing tiles.
- **Add a second way in.** The second shaft (x92–94, y87–89) already reaches
  z11 at the corridor to the north hall. Keep that corridor open, so one jammed
  doorway doesn't stop the hall.
- **Workers commute from far up the fort.** At this survey, forge workers were
  at z18, z96, z100 and z127. A small support room on z11 or z12 cuts that
  walk. It would hold a food and drink pile, a few tables and chairs, and a
  well or water source if one is reachable.

### Layout inside the hall
- **Keep a 1-tile walkway around each workshop block.** Workshops take
  items from any side, and blocked sides slow every job.
- **Bars sit between makers and users.** BAR-Deep is east of the forges and
  north of the smelters. Smelter output walks a few tiles to it, and the forges
  take bars from a few tiles away.
- **Inputs and outputs on opposite sides.** Ore comes in from the west
  (Q11). Finished goods leave from the north-west (FG-Deep), close to the shaft
  they go up.
- **Landing tiles stay out of through-paths.** They go next to the
  smelters, not between the shaft and the workshops.

### Growing the hall
- **Dig sideways on z11 or z12, never down.** Down is magma.
- **East** (beyond x118) gives room for more bar or goods storage.
- **West** (x84–92) gives room for a second landing and its feeder piles.
- **Room on z12:** the z12 level over the hall is open air, so a mezzanine
  needs floors built over it, not dug.
- **Mark new areas restricted until finished,** so through-traffic does not
  form across them.

## Workshop links (set by hand in game)

| Workshop | Take from | Why |
|---|---|---|
| z11 smelters | Q11 (and later C2's landing) | Otherwise they pull ore from ORE-Metal-Smelt at z127. |
| z11 forges | BAR-Deep | At this survey all 4 were fetching nickel bars from z116 and z127, one bar per trip. |

The upper smelters (z116, z127) keep their current piles.

## Q20 once the chute works

Q20 goes away and its tile becomes the chute. Until then it keeps giving to the
upstairs piles. When C1 is dug, also unlink GEM-Rough's take-from-Q20 if gems
should go to the deep hall instead.

## Rollers and power

Rollers push carts, and fast carts climb ramps, so rollers could in principle
return empty carts uphill. They need mechanical power from a water wheel or
windmill, carried down by axles and gears from near the surface.

The chute design never sends a cart uphill, so none of this is needed. On flat
lines, a dwarf push is one short task.

## Order of work

1. Seal the magma stairs (z11 remove-stairs over x112–115, y66–69 and the rest
   of that pocket).
2. Set the workshop links in the table above.
3. Dig chute C1 from z20 down to z13, walling any cavern openings.
4. Drop a test load and watch Q11 fill and the smelters take from it.
5. Point G2's ore at the deep hall, retire Q20, and add feeder piles where the
   z20 ore lies.
6. For each new mining area: a feeder, a flat line, a route and a cart into the
   nearest chute.

## Tools

- `run_blueprint deep_metal`: the z11 piles (phases `q11`, `bars`, `goods`,
  `bins`).
- `run_blueprint g2_pilot`: the z20 line, feeder, Q20, stops, route and cart.
- `set_stockpile_settings`: `stone_untick ["@PLAIN"]`, `blocks_off true`,
  `furniture_types ["BIN"]` after any new pile.
- `minecart_report`: carts, routes, stops and quantum piles.
