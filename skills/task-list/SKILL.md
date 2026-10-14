---
name: task-list
description: This skill should be used when the user runs "/task-list", or asks for the "task list", "queued tasks", "job queue", or "what jobs are queued" in Dwarf Fortress — meaning the live in-game job list (digging, smoothing, hauling, crafting jobs), NOT the manager work orders. Counts queued jobs by type, splits worked vs. waiting, and gives a short read on what is backlog vs. stuck.
---

# Task List (live job queue)

Report the fort's live job queue (`world.jobs.list`): every job currently
posted, whether or not a dwarf has picked it up. This is distinct from manager
**work orders** (`shops_and_orders_report`) — those are standing orders that
*spawn* jobs. No crystal-ball tool exposes the job list yet, so this skill uses
the sanctioned ad-hoc Lua path for a new gap (see CLAUDE.md, "For a genuinely
new gap").

Strictly read-only. Never call any of the seven write ("act") tools.

## Step 1 — Query the job list

Run from `agent/` (output goes via `print()`, not `return`; `utils` must be
`require`d or the script fails with "attempt to index a nil value"):

```python
import sys; sys.path.insert(0, '.')
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
from dfhack_rpc.client import DFHackClient
lua = r"""
local utils=require('utils')
local counts,tot={},0
local w_ct,nw=0,0
for _,j in utils.listpairs(df.global.world.jobs.list) do
  tot=tot+1
  local t=df.job_type[j.job_type] or tostring(j.job_type)
  counts[t]=(counts[t] or 0)+1
  local w=false
  for _,r in ipairs(j.general_refs) do
    if df.general_ref_unit_workerst:is_instance(r) then w=true end
  end
  if w then w_ct=w_ct+1 else nw=nw+1 end
end
local arr={} for k,v in pairs(counts) do arr[#arr+1]={k,v} end
table.sort(arr,function(a,b) return a[2]>b[2] end)
print('TOTAL',tot,'with worker',w_ct,'no worker',nw)
for i,p in ipairs(arr) do if i<=25 then print(p[1],p[2]) end end
print('distinct types',#arr)
"""
with DFHackClient() as c:
    print(c.run_command('lua', [lua]))
```

Run it with `.venv\Scripts\python.exe -` and the script on stdin. If the
connection fails, DF/DFHack isn't running or no fort is loaded — say so plainly
and stop; don't fabricate counts.

## Step 2 — Triage

"With worker" = a dwarf is actively assigned. "No worker" = waiting to be picked
up; a large number here is normal, not a fault by itself. Group the job types:

- **Designation work** — `Dig`, `SmoothFloor`, `SmoothWall`, `DetailFloor`,
  `DetailWall`, `CarveTrack`, `FellTree`, `GatherPlants`. Backlog here is gated
  on miners / smoothers / engravers / woodcutters, not on materials.
- **Hauling** — `StoreItemIn*`, `PickupEquipment`, `StoreOwnedItem`. A big
  backlog suggests too few haulers or full stockpiles.
- **Production** — `Make*`, `Construct*`, `CustomReaction`, `SmeltOre`,
  `MakePotashFromAsh`, `ProcessPlants`. Waiting here points at a busy workshop
  or missing inputs (`shops_and_orders_report` / `diagnose_<industry>`).
- **Everything else** — fishing, pasturing, farming, sleep, etc. Mention only
  if notable.

Report the total, worked/waiting split, and the top job types by count, folding
the long tail into "N other types". Lead with whichever group dominates (by
share of the total). Use exact numbers.

Do **not** claim jobs are *stuck* from counts alone — a count can't tell stuck
from slow. Say the group is gated on a labor/workshop and offer the follow-up
(check suspended jobs, labor coverage via `labor_coverage`, or the matching
`diagnose_*` tool). Only run that follow-up if the user asks.

## Step 3 — Output

Short, scannable: a one-line headline (total, worked vs. waiting), a compact
table of the top job types, then 1-2 sentences of triage naming the dominant
group and what it's gated on. Close with one offered follow-up. No more than
that.

## What NOT to do

- Don't confuse this with manager work orders; if the user clearly means
  those, use `shops_and_orders_report` instead.
- Don't invoke any write/mutation tool.
- Don't list all job types when there are dozens — top ~10 plus a tail count.
- Don't assert jobs are stuck without evidence beyond the count.
