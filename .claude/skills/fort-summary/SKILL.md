---
name: fort-summary
description: This skill should be used when the user runs "/fort-summary", or explicitly asks for a "fort executive summary", "overseer's briefing", "high-level fort status", or "how's my fort doing" in a way that wants a synthesized narrative rather than a raw report dump. Produces a short prose briefing of fortress health for the crystal-ball DFHack MCP server, distinct from the raw, section-by-section fort_briefing tool.
---

# Fort Executive Summary

Produce a short, prose "overseer's briefing" that tells a busy player the state
of their fort in the time it takes to read a paragraph or two: what matters,
what's fine, what to do next. This is a synthesis skill, not a data dump —
`fort_briefing` / `fort_briefing_data` already provide the exhaustive
section-by-section report; this skill's job is to read that data and decide
what's actually worth saying.

This skill is strictly read-only. Never call any of the seven write ("act")
tools (`queue_work_order`, `auto_stock_target`, `fix_idle`,
`manage_containers`, `boost_mood`, `manage_hospital_supplies`, `set_hotkey`)
from within this skill. Recommended actions are described in prose for the
user to run themselves.

## Step 1 — Gather data

Call `mcp__crystal-ball__fort_briefing_data` first. It batches roster, moods,
medical, workshops/orders, key stocks, and cross-industry blockers over a
single DFHack connection — everything the summary needs, in one call.

If that tool is unavailable, fall back to running from `agent/`:
```
.venv\Scripts\python.exe cli.py briefing --json
```

If `fort_loaded` is `false`, stop and report plainly that no fort is loaded —
don't fabricate a briefing.

Then call `mcp__crystal-ball__stock_data` with `refresh=True` to force a full
broad rebuild. This is a deliberate, known-costly step (a paginated scan over
every item on the map) the user has asked to pay on every run — it's the only
way to see item types outside the fixed `_KEY_STOCKS` list (e.g. MEAT/CHEESE
quietly rotting to zero on an unprocessed corpse backlog) rather than just the
11 types `fort_briefing_data` already queries live. Fold anything from this
broad scan into the triage in Step 2 using the same bar as any other blocker
— don't dump the raw category list.

Optionally, pull one or two more targeted tools **only** if they change the
narrative:
- A blocker names a specific industry and its one-line `detail` isn't enough
  to give a concrete recommendation → call that industry's
  `diagnose_<industry>_data` for the ranked root cause.
- Moods list an in-progress mood with a real (non-insane) risk → `mood_report`
  can give the specific missing item to fix it.
- Justice or zones aren't covered by the briefing but the user's phrasing
  suggests they care (e.g. "any prisoners causing trouble?") →
  `justice_data` / `zones_data`.

Don't fan out to every diagnose tool "just in case" — that recreates the
section-by-section report this skill is supposed to distill.

## Step 2 — Decide what matters

Don't report every field. Triage using this priority order (highest first);
the top 2-3 items that clear a real bar become the letter's substance,
everything else is background:

1. **Lost citizens** — any mood with `insane: true`. Always lead with this if present.
2. **Active blockers threatening core survival stocks** (drink/food/seeds at
   or near zero, tied to a blocker in `blockers[]`) — the fort runs out of
   something essential within a season or two.
3. **In-progress moods with blocked requirements** (`blocked_count > 0` and
   `productive: true`) — a citizen is heading toward insanity now.
4. **Hospital gap while wounded exist** — `wounded > 0` and no diagnostician
   (or other critical caregiver role at 0).
5. **Other flagged industry blockers** — real, but not urgent enough to lead with
   unless nothing above applies.
6. **Elevated stress / idle counts** — worth a mention only if notably high
   relative to citizen count (e.g. >15-20% stressed, several idle with open
   orders), never a top-line item on its own.
7. **Everything nominal** — if none of 1-5 apply, say so briefly and move on;
   don't manufacture concern.

For "wins," pick 1-2 genuinely notable positives (e.g. stocks comfortably
healthy, zero blockers across N industries, hospital fully staffed) — skip
generic ones that add no information (e.g. "0 dwarves are dead" is not a win).

Use exact numbers from the tool output. Never round in a way that changes the
meaning (e.g. don't call 2 available drinks "healthy stocks").

## Step 3 — Write the briefing

Voice: a steward or overseer briefing the player, not a system report. Prose
paragraphs, no bullet lists, no section headers other than a single title
line. Roughly 3-5 short paragraphs:

1. **Opening line** — one-sentence overall read (stable / strained / in
   crisis) plus the headline citizen numbers (total, idle, stressed, wounded,
   in mood) folded into a sentence, not a stat block.
2. **The thing that matters** — the top 1-3 items from Step 2's triage, each
   explained in plain language: what's wrong, why it matters, what happens if
   ignored (a timeframe if one is inferable, e.g. "next season", "before winter").
3. **What's going fine** — the 1-2 genuine wins, briefly, as contrast — this
   paragraph can be a sentence or two, not padded to match the others.
4. **Recommended next step(s)** — concrete and actionable, phrased as what the
   player should do, e.g. "queue barrel construction" or "assign a
   diagnostician" — reference the relevant CLI/MCP tool name only if it adds
   clarity (e.g. "`queue_work_order` a ConstructBin order"), not as the whole
   sentence.

If `section_errors` is non-empty, add one short closing sentence noting which
section(s) couldn't be read — don't print the raw error text.

Title the report using the fort/site name if the data exposes one; otherwise
use a generic title like `=== Overseer's Briefing ===`.

### Example

```
=== Overseer's Briefing ===

The fort is stable but strained: 87 citizens, 4 idle, 6 stressed, 1 wounded,
0 in mood. Nothing here is at crisis level yet.

The one real problem is brewing: no empty barrels and the still sits idle.
Drink stocks are still fine today, but at current consumption they run out
within a season if this isn't fixed.

Everything else is holding up well — food and seed stocks are comfortable,
and the other ten industries have no flagged blockers.

Recommended: queue a ConstructBin order to get barrels moving again, then
recheck brewing next season.
```

## What NOT to do

- Don't restate every `_KEY_STOCKS` line or every workshop count — that's
  `fort_briefing`'s job, not this one's.
- Don't invoke any write/mutation tool, even in `preview` mode, unless the
  user separately asks for that.
- Don't pad the summary to a fixed length; a genuinely quiet fort gets a
  short, quiet briefing.
- Don't editorialize beyond what the data supports (no invented lore, no
  speculation about causes the tools didn't report).
