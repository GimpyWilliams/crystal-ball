---
description: Full Dwarf Fortress morning briefing — dwarf moods, hospital, workshops, key stocks, and flagged blockers across all industries. Run this when you load the game.
allowed-tools: [mcp__crystal-ball__dwarf_roster, mcp__crystal-ball__zones_report, mcp__crystal-ball__shops_and_orders_report, mcp__crystal-ball__stock_report, mcp__crystal-ball__brewing_report, mcp__crystal-ball__diagnose_metal, mcp__crystal-ball__diagnose_fuel, mcp__crystal-ball__diagnose_farming, mcp__crystal-ball__diagnose_cooking, mcp__crystal-ball__labor_coverage]
---

# Dwarf Fortress Morning Report

You are generating a full fort status briefing. The player just loaded the game and wants a quick, prioritized picture of where things stand.

## Step 1 — Gather data in parallel

Call ALL of these MCP tools simultaneously (one batch):

- `dwarf_roster` — full citizen list with moods, stress, wounds, what they're doing
- `zones_report` — locations (tavern/temple/hospital) and hospital supply levels
- `shops_and_orders_report` — all workshops and manager orders with status
- `stock_report` — full inventory (key items: DRINK, BAR, WOOD, BOULDER, THREAD, CLOTH, BAG, FOOD)
- `brewing_report` — drink supply and brewing pipeline
- `diagnose_metal` — smelter/forge/ore/fuel pipeline status
- `diagnose_fuel` — charcoal pipeline status
- `diagnose_farming` — crop pipeline status

If any tool call fails (DF not running, etc.), note it and continue with what you have.

## Step 2 — Render the report in this exact structure

### FORT STATUS — [current date from system]

#### Dwarves (N total)
- One line per stress band: how many happy / content / unhappy / miserable
- List any dwarf in a **strange mood** by name
- List all **wounded** dwarves by name
- Flag anyone with stress band "ok" or worse by name and profession
- Note how many are idle vs busy

#### Hospital
- Show each supply as stocked/max — flag any that are at 0 when max > 0 as CRITICAL
- Note if chief medical dwarf is idle while wounded dwarves exist

#### Workshops & Orders
- List workshops that are idle when they have active manager orders (mismatch = blocker)
- List manager orders that are INACTIVE and why (condition not met — show the gap)
- Flag any workshop type with 0 built but active demand

#### Key Stocks
Show these categories with free/total and a one-line status:
- Drinks (target: >100)
- Food/plants
- Wood logs
- Metal ore boulders
- Fuel (charcoal/coke bars)
- Thread & cloth
- Bags (empty = critical for glass/sand)
- Rough gems

#### Industry Pipeline Flags
For each industry below, one line: RUNNING / READY (no orders) / BLOCKED (why):
- **Fuel** (charcoal)
- **Smelting** (pig iron)
- **Forging** (metal goods)
- **Brewing**
- **Farming**
- **Glass** (note sand bag situation)
- **Weaving** (silk thread on hand?)
- **Gem cutting**

#### Top 3 Action Items
Rank the 3 most impactful things to do right now, in plain language. Be specific — name the manager order to queue, the supply to restock, the labor to enable.

## Formatting rules
- Use emoji sparingly: only for CRITICAL flags (use ⚠️) and all-clear sections (use ✓)
- Keep each section tight — no prose, just facts and flags
- If a section is all-clear, one line: "✓ No issues"
- Never repeat data across sections
