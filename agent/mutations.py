"""
WRITE ("act") features for crystal-ball: the only tools in this project that can
change game state. Each feature is one function exposed with a mode parameter:

    mode='advise'   read-only; explains what it WOULD do + manual click-path.
    mode='preview'  read-only; the exact orders it would create, no write.
    mode='apply'    writes -- and ONLY when confirm=True.

Safety model (locked with the user):
  * apply re-derives its plan from LIVE state every call (the planners below read
    the fort fresh), and refuses if preconditions fail.
  * apply additionally requires confirm=True, on top of the MCP host's own
    per-tool permission prompt.
  * apply performs only REVERSIBLE actions: it creates manager orders (cancellable
    in-game in one click). Anything structural -- designating a tavern/temple/
    library zone, placing a workshop -- is returned as advice TEXT only, never
    written.

All writes funnel through actions.run_action('create_order.lua', ...), whose Lua
validates every enum before mutating and pcall-wraps each insert.
"""

import json

from actions import run_action
from intel import as_map, shared_connection
from pipelines import fetch_containers, fetch_shops_and_orders, fetch_stock
from dwarves import fetch_roster

# --- job_type / reaction names (verified against the live DF build) ---------
# These are version-sensitive; the mutation Lua validates each against df.job_type
# (and the reaction list) and refuses gracefully -- no crash -- if a name is
# wrong on a given build, so correcting one is a one-line, low-risk change.
# NOTE on this build: there is no "BrewDrink" job (brewing is a CustomReaction),
# no "MakeBin" (it's "ConstructBin"), and the material_category bitfield is
# organic-only (no "stone"/"metal" flag) -- so stone work is queued generically.
JOB_CRAFTS = "MakeCrafts"
JOB_BLOCKS = "ConstructBlocks"
JOB_WEAVE = "WeaveCloth"
JOB_MECHANISMS = "ConstructMechanisms"
JOB_BIN = "ConstructBin"
JOB_CUSTOM = "CustomReaction"
REACTION_BREW = "BREW_DRINK_FROM_PLANT"

# Only organic classes are representable in the order material_category bitfield.
# Inorganic requests (stone/metal/glass) and 'any' fall through to no pin, which
# lets the manager pick whatever's available (fine for absorbing idle labor).
_MATERIAL_TO_CATEGORY = {
    "wood": "wood", "cloth": "cloth", "silk": "silk", "yarn": "yarn",
    "leather": "leather", "bone": "bone", "shell": "shell", "plant": "plant",
}


def _matcat(material):
    return _MATERIAL_TO_CATEGORY.get(material)  # None for any/stone/metal/...


# Generic "rock": DF encodes stone as the (mat_type, mat_index) pair (0, -1) --
# the same encoding a UI-made "make rock crafts" / statue order uses.
STONE = {"mat_type": 0, "mat_index": -1}


def _resolve_material(material):
    """Turn a material string into the order-spec fields the Lua expects.
    'stone'/'rock' -> (0,-1); an organic class -> material_category; anything
    else is treated as a concrete material NAME for the game to resolve. 'any'
    and None resolve to {} (left to the job's material-required guard)."""
    if material in (None, "any"):
        return {}
    if material in ("stone", "rock"):
        return dict(STONE)
    cat = _matcat(material)
    if cat:
        return {"material_category": cat}
    return {"material_name": material}  # e.g. "MICROCLINE", "GRANITE"


# --- plan plumbing ----------------------------------------------------------

def _plan(valid, summary, *, orders=None, facts=None, advice=None, reason="",
          changes=None, action_script=None, action_payload=None,
          render_result=None):
    """A render-able action plan. The order writers use `orders` (applied via the
    default create_order.lua). A non-order writer instead sets `action_script` +
    `action_payload` (the JSON spec to send) and describes the effect with
    `changes` (human strings) + a `render_result` callable for the apply output."""
    return {
        "valid": valid, "summary": summary, "reason": reason,
        "orders": orders or [], "facts": facts or [], "advice": advice or [],
        "changes": changes or [], "action_script": action_script,
        "action_payload": action_payload, "render_result": render_result,
    }


def _free(stock, category):
    c = as_map(as_map(stock.get("categories")).get(category))
    return c.get("free_units", 0)


def _shop_idle(shops, type_name):
    s = as_map(as_map(shops.get("workshops")).get(type_name))
    return s.get("idle", 0)


def _render(plan, mode, confirm, host, port):
    """Shared advise/preview/apply renderer for every feature."""
    if mode == "advise":
        return _advise_body(plan)
    if mode == "preview":
        return _preview_body(plan)
    if mode == "apply":
        return _apply(plan, confirm, host, port)
    return (f"unknown mode {mode!r}; use 'advise' (default), 'preview', "
            "or 'apply'")


def _facts_block(plan):
    if not plan["facts"]:
        return ""
    return "\nCurrent state:\n" + "\n".join(f"  {f}" for f in plan["facts"])


def _work_block(plan):
    """Render the action's effect: manager orders, or a generic change list for
    non-order writers (e.g. hospital-supply edits)."""
    if not plan["orders"] and plan.get("changes"):
        lines = ["\nChanges it would make:"]
        lines += [f"  - {c}" for c in plan["changes"]]
        return "\n".join(lines)
    return _orders_block(plan)


def _orders_block(plan):
    if not plan["orders"]:
        return "\n(Nothing to queue.)"
    lines = ["\nOrders it would create:"]
    for o in plan["orders"]:
        cond = ""
        if o.get("condition"):
            c = o["condition"]
            cond = f"  [only when {c.get('item_type','item')} < {c.get('below')}]"
        mat = _describe_material(o)
        freq = o.get("frequency", "one-time")
        lines.append(f"  - {o.get('label', o['job'])}: {o['amount']}x, "
                     f"material={mat}, repeat={freq}{cond}")
    return "\n".join(lines)


def _describe_material(o):
    """Human label for an order's material across the encodings we emit."""
    if o.get("reaction_name"):
        return "reaction-defined"
    if o.get("material_name"):
        return str(o["material_name"])
    if o.get("mat_type") == 0 and o.get("mat_index", -1) == -1:
        return "rock (generic stone)"
    if o.get("material_category"):
        return o["material_category"]
    return "any"


def _advise_body(plan):
    lines = [plan["summary"]]
    lines.append(_facts_block(plan))
    if plan["advice"]:
        lines.append("\nDo it yourself (manual steps):")
        lines += [f"  {a}" for a in plan["advice"]]
    lines.append(_work_block(plan))
    lines.append("\nTo let me apply this for you, call again with mode='preview' "
                 "to see the exact plan, then mode='apply', confirm=true.")
    return "\n".join(p for p in lines if p)


def _preview_body(plan):
    if not plan["valid"]:
        return f"Cannot apply: {plan['reason']}"
    lines = [f"PREVIEW (nothing written): {plan['summary']}"]
    lines.append(_facts_block(plan))
    lines.append(_work_block(plan))
    lines.append("\nThis preview made NO changes. To execute, call again with "
                 "mode='apply', confirm=true.")
    return "\n".join(p for p in lines if p)


def _apply(plan, confirm, host, port):
    if not plan["valid"]:
        return f"Refusing to apply: {plan['reason']}"
    # Resolve the mutation to run: order writers default to create_order.lua with
    # the plan's orders; other writers supply their own script + JSON payload.
    script = plan.get("action_script") or "create_order.lua"
    payload = plan.get("action_payload")
    if payload is None:
        payload = {"orders": plan["orders"]}
    if script == "create_order.lua" and not plan["orders"]:
        return "Nothing to do -- no orders to create."
    if not confirm:
        return ("apply requires confirm=true (this WRITES to the live game).\n\n"
                + _preview_body(plan))
    res = run_action(script, [json.dumps(payload)], host=host, port=port)
    renderer = plan.get("render_result") or _format_result
    return renderer(res)


def _format_result(res):
    created = res.get("created") or []
    errs = res.get("errors") or []
    if not res.get("ok"):
        lines = ["Apply did not fully succeed."]
        if created:
            lines.append(f"(Created {len(created)} order(s) before the problem.)")
        lines.append("Problems:")
        lines += [f"  - {e}" for e in errs]
        return "\n".join(lines)
    lines = [f"Done. Created {len(created)} manager order(s):"]
    for c in created:
        lines.append(f"  #{c.get('id')}  {c.get('label', c.get('job'))} "
                     f"x{c.get('amount')}")
    if errs:
        lines.append("Some specs were skipped:")
        lines += [f"  - {e}" for e in errs]
    lines.append("\nReversible: cancel any of these in-game via the "
                 "Manager/Tasks (j-m) menu.")
    return "\n".join(lines)


# --- 1. queue_work_order ----------------------------------------------------

def queue_work_order(job, amount=10, material="any", frequency="one-time",
                     mode="advise", confirm=False,
                     host="127.0.0.1", port=5000):
    """Create a single manager order. `job` is a df.job_type name (e.g.
    'MakeCrafts', 'BrewDrink', 'WeaveCloth')."""
    order = {"job": job, "amount": int(amount), "frequency": frequency,
             "label": f"{job} ({material})", **_resolve_material(material)}
    plan = _plan(
        True, f"Queue {amount}x '{job}' (material={material}, repeat={frequency}).",
        orders=[order],
        advice=[f"Open Manager orders (j-m), add a new order, choose '{job}', "
                f"set quantity {amount}" +
                (f", repeat {frequency}." if frequency != "one-time" else ".")],
    )
    return _render(plan, mode, confirm, host, port)


# --- 2. auto_stock_target ---------------------------------------------------

# Items we know how to replenish without the caller naming a job. Value is
# (job, reaction_name) -- reaction_name is "" for plain jobs.
_STOCK_TARGET_JOBS = {"DRINK": (JOB_CUSTOM, REACTION_BREW)}


def auto_stock_target(item, target, job=None, material="any", frequency="daily",
                      mode="advise", confirm=False,
                      host="127.0.0.1", port=5000):
    """Create a conditional repeat order that keeps >= `target` of `item` on hand
    (DF 'when AMOUNT < target'). `item` is a df.item_type name (e.g. 'DRINK')."""
    reaction = ""
    if not job:
        known = _STOCK_TARGET_JOBS.get(item)
        if known:
            job, reaction = known
    # Targeted read of just this one type -- instant, vs a ~10s full-fort scan to
    # read one number (and it warms the stock baseline as a side effect).
    stock = fetch_stock(item, host=host, port=port)
    if not stock.get("fort_loaded"):
        return _render(_plan(False, "", reason="no fortress is loaded"),
                       mode, confirm, host, port)
    have = _free(stock, item)
    if not job:
        plan = _plan(False, "",
                     reason=f"don't know which job makes {item}; pass job=...")
    else:
        order = {"job": job, "reaction_name": reaction,
                 "amount": int(target), "material_category": _matcat(material),
                 "frequency": frequency,
                 "condition": {"item_type": item, "below": int(target)},
                 "label": f"keep {item} >= {target}"}
        plan = _plan(
            True,
            f"Keep at least {target} {item} on hand (auto-brew when below).",
            orders=[order],
            facts=[f"{item} on hand now: {have} (target {target})"],
            advice=[f"Add a '{job}' manager order, set quantity {target}, set "
                    f"repeat {frequency}, then add a condition: "
                    f"amount of {item} < {target}."],
        )
    return _render(plan, mode, confirm, host, port)


# --- 3. fix_idle ------------------------------------------------------------

def fix_idle(mode="advise", confirm=False, host="127.0.0.1", port=5000):
    """Absorb idle dwarves: queue stone-craft / weaving / mechanism orders
    matched to idle workshops and surplus inputs."""
    # One shared socket for the three reads instead of three handshakes.
    with shared_connection(host, port):
        roster = fetch_roster(host=host, port=port)
        shops = fetch_shops_and_orders(host=host, port=port)
        # Targeted reads of only the two types we need (both vector-complete, so the
        # focused count is exact) instead of a full-fort scan for two numbers.
        boulders = _free(fetch_stock("BOULDER", host=host, port=port), "BOULDER")
        thread = _free(fetch_stock("THREAD", host=host, port=port), "THREAD")
    if not roster.get("fort_loaded"):
        return _render(_plan(False, "", reason="no fortress is loaded"),
                       mode, confirm, host, port)

    idle_dwarves = sum(1 for d in (roster.get("dwarves") or [])
                       if d.get("activity") == "Idle")
    facts = [f"idle dwarves: {idle_dwarves}",
             f"boulders free: {boulders}, thread free: {thread}"]

    orders, advice = [], []
    amt = max(10, min(idle_dwarves * 3, 30)) if idle_dwarves else 10
    # Match each idle workshop to a job it ACTUALLY does, with a real material
    # (generic rock = mat_type 0 / mat_index -1, the UI's "rock" encoding).
    if _shop_idle(shops, "Craftsdwarfs") and boulders >= 10:
        orders.append({"job": JOB_CRAFTS, "amount": amt,
                       "label": "rock crafts (idle craftsdwarf's)", **STONE})
    elif boulders >= 10:
        advice.append("You have no Craftsdwarf's workshop -- build one to turn "
                      "surplus stone into trade crafts (Masons can't make crafts).")
    if _shop_idle(shops, "Masons") and boulders >= 10:
        orders.append({"job": JOB_BLOCKS, "amount": amt,
                       "label": "cut stone blocks (idle masons)", **STONE})
    if _shop_idle(shops, "Mechanics") and boulders >= 10:
        orders.append({"job": JOB_MECHANISMS, "amount": max(5, amt // 2),
                       "label": "mechanisms (idle mechanics)", **STONE})
    if _shop_idle(shops, "Loom") and thread >= 10:
        # Weaving needs a thread class; their backlog is silk. A class that
        # doesn't match just sits idle (harmless) rather than going malformed.
        orders.append({"job": JOB_WEAVE, "amount": amt,
                       "material_category": "silk",
                       "label": "weave silk cloth (drain thread backlog)"})
        advice.append("Loom is idle and thread is piled up -- weaving also "
                      "clothes your dwarves (a recurring need).")

    if not orders:
        valid = False
        reason = ("no clear idle-work match (no idle masons/mechanics/loom with "
                  "surplus inputs). Build a Craftsdwarf's workshop or check stock.")
        summary = ""
    else:
        valid = True
        reason = ""
        summary = (f"Put idle dwarves to work: {len(orders)} order(s) matched to "
                   "idle workshops and surplus materials.")
    plan = _plan(valid, summary, orders=orders, facts=facts, advice=advice,
                 reason=reason)
    return _render(plan, mode, confirm, host, port)


# --- 4. manage_containers ---------------------------------------------------

def manage_containers(mode="advise", confirm=False, host="127.0.0.1", port=5000):
    """Fix a storage-container crunch by queuing pot/bin production. Stockpile
    re-assignment is advice-only (it is not a simple reversible write)."""
    cont = fetch_containers(host=host, port=port)
    if not cont.get("fort_loaded"):
        return _render(_plan(False, "", reason="no fortress is loaded"),
                       mode, confirm, host, port)
    barrels = as_map(cont.get("barrels"))
    pots = as_map(cont.get("large_pots"))
    bins = as_map(cont.get("bins"))
    facts = [
        f"barrels: {barrels.get('total',0)} total, {barrels.get('empty',0)} empty",
        f"large pots: {pots.get('total',0)} total, {pots.get('empty',0)} empty",
        f"bins: {bins.get('total',0)} total, {bins.get('empty',0)} empty",
    ]

    orders, advice = [], []
    if bins.get("empty", 0) == 0:
        orders.append({"job": JOB_BIN, "amount": 10, "material_category": "wood",
                       "label": "wooden bins (goods storage)"})
    if pots.get("empty", 0) == 0:
        advice.append("No empty large pots. Rock pots are a tool (need an item "
                      "subtype this tool won't guess) -- queue 'make rock pot' "
                      "at a Craftsdwarf's/Kiln yourself for food/drink storage.")
    if barrels.get("total", 0) and barrels.get("empty", 0) == 0:
        advice.append("All barrels are full -- queue a few MakeBarrel orders or "
                      "the rock pots above for more food/drink storage.")
    advice.append("After containers are built, point a stockpile at them (this "
                  "part I leave to you: it is not a cleanly reversible write).")

    if not orders:
        plan = _plan(False, "",
                     reason="storage looks fine -- empty pots and bins exist.",
                     facts=facts)
    else:
        plan = _plan(True,
                     f"Relieve the storage crunch: queue {len(orders)} "
                     "container-production order(s).",
                     orders=orders, facts=facts, advice=advice)
    return _render(plan, mode, confirm, host, port)


# --- 5. boost_mood ----------------------------------------------------------

def boost_mood(mode="advise", confirm=False, host="127.0.0.1", port=5000):
    """Raise fort mood with reversible actions (top up alcohol). Designating
    tavern/temple/library zones is advice-only."""
    with shared_connection(host, port):
        roster = fetch_roster(host=host, port=port)
        # Targeted read of just DRINK (vector-complete -> exact) instead of a full scan.
        drinks = _free(fetch_stock("DRINK", host=host, port=port), "DRINK")
    if not roster.get("fort_loaded"):
        return _render(_plan(False, "", reason="no fortress is loaded"),
                       mode, confirm, host, port)

    dwarves = roster.get("dwarves") or []
    total_unmet = sum(d.get("unmet_needs", 0) for d in dwarves)
    worst = sorted(dwarves, key=lambda d: -(d.get("unmet_needs") or 0))[:3]
    n_dwarves = len(dwarves) or 1
    facts = [f"total unmet needs across fort: {total_unmet}",
             f"drinks on hand: {drinks} (~{drinks // n_dwarves} per dwarf)"]
    for d in worst:
        facts.append(f"worst: {d.get('name','?')} -- "
                     f"{d.get('unmet_needs',0)} unmet need(s)")

    orders, advice = [], []
    if drinks < n_dwarves * 5:
        orders.append({"job": JOB_CUSTOM, "reaction_name": REACTION_BREW,
                       "amount": 20,
                       "label": "brew drinks (low alcohol stresses everyone)"})
    advice += [
        "Designate a TAVERN zone over your dining hall (z -> Locations) so "
        "dwarves can socialize and drink -- this is the biggest mood lever and "
        "I leave the zone designation to you.",
        "Designate a TEMPLE and a LIBRARY similarly for the prayer/study needs.",
        "Smooth & engrave walls/floors in common areas for passive happy thoughts.",
        "Treat the wounded -- untreated wounds are a constant mood drain.",
    ]
    if not orders:
        summary = "Mood levers are mostly zone-based here (see manual steps)."
        valid = bool(orders)
        reason = "no reversible order helps right now; the wins are zone-based."
    else:
        summary = ("Boost mood: top up alcohol now; designate social zones "
                   "yourself for the big wins.")
        valid, reason = True, ""
    plan = _plan(valid, summary, orders=orders, facts=facts, advice=advice,
                 reason=reason)
    # advise mode is always useful even when there's no order to apply.
    if mode == "advise":
        return _advise_body(plan)
    return _render(plan, mode, confirm, host, port)


# --- 6. set_hospital_supplies (reversible, non-order write) ------------------
# The only zone/location write. It stays inside the locked safety model: it does
# NOT create/delete/resize/designate -- it edits an EXISTING hospital location's
# desired-supply maximums (contents.desired_*), which is trivially reversible
# (set the number back). Zone *creation* remains advice-only (see boost_mood).

def _format_zone_result(res):
    """Apply-result renderer for hospital-supply edits (mirrors _format_result)."""
    created = res.get("created") or []
    errs = res.get("errors") or []
    if not res.get("ok"):
        lines = ["Apply did not fully succeed."]
        if created:
            lines.append(f"(Changed {len(created)} setting(s) before the problem.)")
        lines.append("Problems:")
        lines += [f"  - {e}" for e in errs]
        return "\n".join(lines)
    lines = [f"Done. Updated {len(created)} hospital supply setting(s):"]
    for c in created:
        lines.append(f"  {c.get('field')}: {c.get('old')} -> {c.get('new')} "
                     f"(on {c.get('hospital')})")
    if errs:
        lines.append("Some settings were skipped:")
        lines += [f"  - {e}" for e in errs]
    lines.append("\nReversible: set the same field back to its previous value "
                 "(shown above) to undo.")
    return "\n".join(lines)


# --- 7. set_hotkey (reversible, non-order write) ----------------------------
# Edits one slot in df.global.plotinfo.main.hotkeys[]: name, x/y/z, cmd.
# cmd=0 activates the slot (zoom-to-map-location); cmd=-1 clears it.
# Trivially reversible: set the slot back to its previous values.

def _format_hotkey_result(res):
    """Apply-result renderer for hotkey writes (mirrors _format_zone_result)."""
    created = res.get("created") or []
    errs = res.get("errors") or []
    if not res.get("ok"):
        lines = ["Apply did not fully succeed.", "Problems:"]
        lines += [f"  - {e}" for e in errs]
        return "\n".join(lines)
    lines = []
    for c in created:
        old = c.get("old") or {}
        new = c.get("new") or {}
        key = c.get("key", "?")
        if new.get("active"):
            lines.append(f"Done. {key} set to '{new.get('name')}' at "
                         f"({new.get('x')}, {new.get('y')}, {new.get('z')}).")
        else:
            lines.append(f"Done. {key} cleared.")
        old_desc = (f"'{old.get('name')}' at "
                    f"({old.get('x')}, {old.get('y')}, {old.get('z')})"
                    if old.get("active") else "unset")
        lines.append(f"Previous state: {old_desc}.")
    if errs:
        lines.append("Some specs were skipped:")
        lines += [f"  - {e}" for e in errs]
    lines.append("\nReversible: call set_hotkey again with the previous values "
                 "shown above to restore, or clear with name=''.")
    return "\n".join(lines)


def set_hotkey(key_id, name, x=0, y=0, z=0, mode="advise", confirm=False,
               host="127.0.0.1", port=5000):
    """Set or clear an F-key map bookmark (reversible). `key_id` is 1-16 (F1-F16).
    Pass a non-empty `name` with `x`/`y`/`z` to set the bookmark; pass name=''
    to clear the slot."""
    from hotkeys import fetch_hotkeys_intel

    # Validate inputs Python-side for friendly error messages.
    try:
        kid = int(key_id)
    except (TypeError, ValueError):
        return _render(_plan(False, "", reason="key_id must be an integer 1-16"),
                       mode, confirm, host, port)
    if not 1 <= kid <= 16:
        return _render(_plan(False, "",
                             reason=f"key_id {kid} is out of range; must be 1-16"),
                       mode, confirm, host, port)

    name = str(name) if name is not None else ""
    clearing = (name == "")

    if not clearing:
        try:
            x, y, z = int(x), int(y), int(z)
        except (TypeError, ValueError):
            return _render(_plan(False, "", reason="x, y, z must be integers"),
                           mode, confirm, host, port)

    # Read live state to show old -> new in preview/advise.
    data = fetch_hotkeys_intel(host=host, port=port)
    if not data.get("fort_loaded"):
        return _render(_plan(False, "", reason="no fortress is loaded"),
                       mode, confirm, host, port)
    hotkeys = data.get("hotkeys") or []
    if len(hotkeys) < kid:
        return _render(_plan(False, "", reason=f"no hotkey slot F{kid}"),
                       mode, confirm, host, port)

    cur = hotkeys[kid - 1]
    key_label = f"F{kid}"
    cur_active = cur.get("active")

    if clearing:
        summary = (f"Clear map bookmark {key_label} "
                   f"(currently '{cur.get('name', '')}').")
        old_desc = (f"'{cur.get('name')}' at "
                    f"({cur.get('x')}, {cur.get('y')}, {cur.get('z')})"
                    if cur_active else "already unset")
        changes = [f"{key_label}: {old_desc} -> cleared"]
        advice = [f"In-game: press h (Hotkeys), select {key_label}, and "
                  "clear the name field."]
    else:
        prev_desc = (f"'{cur.get('name')}' at "
                     f"({cur.get('x')}, {cur.get('y')}, {cur.get('z')})"
                     if cur_active else "unset")
        summary = f"Set {key_label} map bookmark to '{name}' at ({x}, {y}, {z})."
        changes = [f"{key_label}: {prev_desc} -> '{name}' at ({x}, {y}, {z})"]
        advice = [f"In-game: navigate the camera to ({x}, {y}, {z}), press h "
                  f"(Hotkeys), select {key_label}, and set the name to '{name}'."]

    facts = [
        f"{key_label} current state: "
        + (f"'{cur.get('name')}' at "
           f"({cur.get('x')}, {cur.get('y')}, {cur.get('z')})"
           if cur_active else "unset")
    ]

    plan = _plan(
        True, summary,
        facts=facts, changes=changes, advice=advice,
        action_script="set_hotkey.lua",
        action_payload={"key_id": kid, "name": name,
                        "x": x if not clearing else 0,
                        "y": y if not clearing else 0,
                        "z": z if not clearing else 0},
        render_result=_format_hotkey_result,
    )
    return _render(plan, mode, confirm, host, port)


# --- 8. rename_stockpiles (reversible, label-only write) --------------------
# Sets building_stockpilest.name. Changes the display label only -- never what a
# pile accepts, its extents, links or contents. Reversible: rename back.

_NAME_MAX = 40
_NAME_OK = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
               "0123456789-_ /")


def _format_rename_result(res):
    created = res.get("created") or []
    errs = res.get("errors") or []
    if not res.get("ok"):
        lines = ["Apply did not fully succeed (validation failures write nothing).",
                 "Problems:"]
        lines += [f"  - {e}" for e in errs]
        if created:
            lines.insert(1, f"({len(created)} rename(s) applied before the problem.)")
        return "\n".join(lines)
    lines = [f"Done. Renamed {len(created)} stockpile(s):"]
    for c in sorted(created, key=lambda c: c.get("number", 0)):
        lines.append(f"  #{c.get('number')}: {c.get('old') or '(unnamed)'!r} -> "
                     f"{c.get('new')!r}")
    lines.append("\nReversible: call rename_stockpiles again with the old names "
                 "shown above (use the pile's current name as the old one).")
    return "\n".join(lines)


def rename_stockpiles(renames, mode="advise", confirm=False,
                      host="127.0.0.1", port=5000):
    """Rename stockpiles by number (reversible, label only). `renames` maps a
    stockpile number to its new name, e.g. {16: "FURN-Stone"}. The plan is built
    from the LIVE names; the Lua refuses any pile whose name changed since."""
    from pipelines import fetch_stockpile_config

    # 1. Validate inputs python-side for friendly messages (the Lua revalidates).
    errors, clean = [], {}
    for k, v in (renames or {}).items():
        try:
            num = int(k)
        except (TypeError, ValueError):
            errors.append(f"{k!r}: stockpile number must be an integer")
            continue
        name = str(v).strip() if v is not None else ""
        if not name or len(name) > _NAME_MAX:
            errors.append(f"#{num}: name must be 1-{_NAME_MAX} characters")
        elif any(ch not in _NAME_OK for ch in name):
            errors.append(f"#{num}: {name!r} may only use letters, digits, "
                          "space, - _ /")
        else:
            clean[num] = name
    dupes = {n for n in clean.values() if list(clean.values()).count(n) > 1}
    if dupes:
        errors.append("duplicate new names: " + ", ".join(sorted(dupes)))
    if errors:
        return _render(_plan(False, "", reason="; ".join(errors)),
                       mode, confirm, host, port)
    if not clean:
        return _render(_plan(False, "", reason="no renames given"),
                       mode, confirm, host, port)

    # 2. Read the live names so the plan shows old -> new and apply can detect drift.
    data = fetch_stockpile_config(host=host, port=port)
    if not data.get("fort_loaded"):
        return _render(_plan(False, "", reason="no fortress is loaded"),
                       mode, confirm, host, port)
    live = {s.get("number"): s for s in (data.get("stockpiles") or [])}
    missing = sorted(n for n in clean if n not in live)
    if missing:
        return _render(_plan(False, "", reason="no stockpile numbered "
                       + ", ".join(f"#{n}" for n in missing)),
                       mode, confirm, host, port)
    held = {live[n].get("name") or "" for n in live if n not in clean}
    clash = sorted(n for n in clean.values() if n in held)
    if clash:
        return _render(_plan(False, "", reason="name(s) already used by a pile "
                       "not being renamed: " + ", ".join(clash)),
                       mode, confirm, host, port)

    changes, payload, same = [], [], 0
    for num in sorted(clean):
        old = live[num].get("name") or ""
        if old == clean[num]:
            same += 1
            continue
        p = live[num].get("pos") or {}
        where = f" [z{p['z']}]" if "z" in p else ""
        changes.append(f"#{num}{where}: {old or '(unnamed)'!r} -> {clean[num]!r}")
        payload.append({"number": num, "expect_old": old, "new": clean[num]})
    if not payload:
        return _render(_plan(False, "", reason="every pile already has the "
                       "requested name"), mode, confirm, host, port)

    facts = [f"{len(payload)} of {len(live)} stockpiles would be renamed"
             + (f" ({same} already match)" if same else "")]
    plan = _plan(
        True, f"Rename {len(payload)} stockpile(s) (label only).",
        facts=facts, changes=changes,
        advice=["In-game: select the stockpile, open its settings, and edit the "
                "name field at the top. Names do not change what a pile accepts."],
        action_script="rename_stockpiles.lua",
        action_payload={"renames": payload},
        render_result=_format_rename_result,
    )
    return _render(plan, mode, confirm, host, port)


# --- 9. set_stockpile_settings (reversible, furniture types + container caps) -
# Sets one category's accept-filter (Furniture types) and the bin / barrel /
# wheelbarrow caps. Never touches other categories, names, extents or links.
# Reversible: the apply result lists each pile's old state to set back.

_CAP_KEYS = ("max_bins", "max_barrels", "max_wheelbarrows")
_FURN_MODES = ("furniture_types", "furniture_except", "untick_types",
               "disable_furniture")
_QUALITIES = ("Ordinary", "WellCrafted", "FinelyCrafted", "Superior",
              "Exceptional", "Masterful", "Artifact")


def _norm_quality(v):
    """'Finely-crafted' / 'finelycrafted' / 2 -> the df.item_quality name."""
    if isinstance(v, int) and not isinstance(v, bool) and 0 <= v < len(_QUALITIES):
        return _QUALITIES[v]
    key = "".join(ch for ch in str(v).lower() if ch.isalpha())
    for q in _QUALITIES:
        if q.lower() == key:
            return q
    return None


def _furn_desc(sp):
    if "furniture" not in (sp.get("accepts") or []):
        return "Furniture off"
    off = sp.get("furniture_off") or []
    on = sp.get("furniture_types") or []
    if not off:
        return "all furniture types"
    if len(on) <= len(off):
        return "only " + ", ".join(on) if on else "no furniture types"
    return "all furniture types except " + ", ".join(off)


def _format_settings_result(res):
    created = res.get("created") or []
    errs = res.get("errors") or []
    if not res.get("ok"):
        lines = ["Apply did not fully succeed (validation failures write nothing).",
                 "Problems:"]
        lines += [f"  - {e}" for e in errs]
        if created:
            lines.insert(1, f"({len(created)} pile(s) changed before the problem.)")
        return "\n".join(lines)
    lines = [f"Done. Updated {len(created)} stockpile(s):"]
    for c in sorted(created, key=lambda c: c.get("number", 0)):
        b, a = as_map(c.get("before")), as_map(c.get("after"))
        lines.append(f"  #{c.get('number')} {c.get('name') or '(unnamed)'}:")
        for label, s in (("before", b), ("after", a)):
            types = s.get("types") or []
            furn = (("furniture " + ", ".join(types)) if types
                    else "no furniture types") \
                if s.get("furniture") else "Furniture off"
            fg = s.get("fg_types") or []
            fgs = (("finished goods " + (", ".join(fg) if len(fg) < 20
                                         else f"{len(fg)} types"))
                   if s.get("finished_goods") else "Finished goods off")
            if s.get("finished_goods"):
                fgs += (f" ({s.get('fg_mat_count')} materials"
                        + ("" if s.get("fg_other_mat_count") else ", no organics")
                        + ")")
            if s.get("coins"):
                fgs += f"; coins ({s.get('coin_mat_count')} materials)"
            qs = ((s.get("fg_qualities") if s.get("finished_goods") else None)
                  or (s.get("furniture_qualities") if s.get("furniture") else None)
                  or [])
            q = (f"quality {qs[0]}+" if qs and len(qs) < len(_QUALITIES)
                 else "any quality")
            caps = " ".join(f"{k[4:]}={s.get(k)}" for k in _CAP_KEYS)
            lines.append(f"    {label}: {furn}; {fgs}; {q}; {caps}")
    lines.append("\nReversible: call set_stockpile_settings again with the "
                 "'before' values shown above.")
    return "\n".join(lines)


def set_stockpile_settings(piles, mode="advise", confirm=False,
                           host="127.0.0.1", port=5000):
    """Set Furniture accept-types and container caps on stockpiles by number
    (reversible). `piles` maps a number to a dict with at most one of
    furniture_types (exact list; enables Furniture), furniture_except (every
    type but these), untick_types (list to turn off) or disable_furniture
    (true), plus optional finished_goods_types (exact df.item_type list;
    enables Finished goods), min_quality (applies to the categories set), and
    max_bins / max_barrels / max_wheelbarrows. The plan is built from live config; the Lua refuses any
    pile whose name changed since."""
    from pipelines import fetch_stockpile_config

    # 1. Validate inputs python-side for friendly messages (the Lua revalidates).
    errors, clean = [], {}
    for k, v in (piles or {}).items():
        try:
            num = int(k)
        except (TypeError, ValueError):
            errors.append(f"{k!r}: stockpile number must be an integer")
            continue
        v = as_map(v)
        unknown = sorted(set(v) - set(_CAP_KEYS) - set(_FURN_MODES)
                         - {"finished_goods_types", "min_quality",
                            "finished_goods_materials",
                            "finished_goods_materials_except",
                            "finished_goods_other_materials",
                            "coin_materials"})
        if unknown:
            errors.append(f"#{num}: unknown field(s) {', '.join(unknown)}")
            continue
        modes = [m for m in _FURN_MODES if v.get(m)]
        if len(modes) > 1:
            errors.append(f"#{num}: give only one of {', '.join(_FURN_MODES)}")
            continue
        entry = {}
        for m in modes:
            if m == "disable_furniture":
                entry[m] = True
            elif not isinstance(v[m], list) or not v[m]:
                errors.append(f"#{num}: {m} must be a non-empty list")
            else:
                entry[m] = [str(t).strip().upper() for t in v[m]]
        if "finished_goods_types" in v:
            fg = v["finished_goods_types"]
            if not isinstance(fg, list) or not fg:
                errors.append(f"#{num}: finished_goods_types must be a non-empty list")
            else:
                entry["finished_goods_types"] = [str(x).strip().upper() for x in fg]
        for key in ("finished_goods_materials", "finished_goods_materials_except",
                    "coin_materials"):
            if key in v:
                m = v[key]
                if not isinstance(m, list) or not m:
                    errors.append(f"#{num}: {key} must be a non-empty list")
                else:
                    entry[key] = [str(x).strip().upper() for x in m]
        if "finished_goods_materials_except" in entry                 and "finished_goods_materials" not in entry:
            errors.append(f"#{num}: finished_goods_materials_except needs "
                          "finished_goods_materials")
        if "finished_goods_other_materials" in v:
            if not isinstance(v["finished_goods_other_materials"], bool):
                errors.append(f"#{num}: finished_goods_other_materials must be "
                              "true or false")
            else:
                entry["finished_goods_other_materials"] =                     v["finished_goods_other_materials"]
        if "min_quality" in v:
            q = _norm_quality(v["min_quality"])
            if q is None:
                errors.append(f"#{num}: unknown quality {v['min_quality']!r} "
                              f"(use {', '.join(_QUALITIES)})")
            else:
                entry["min_quality"] = q
        for cap in _CAP_KEYS:
            if cap in v:
                try:
                    n = int(v[cap])
                except (TypeError, ValueError):
                    errors.append(f"#{num}: {cap} must be an integer")
                    continue
                if n < 0:
                    errors.append(f"#{num}: {cap} must be >= 0")
                    continue
                entry[cap] = n
        if not entry:
            errors.append(f"#{num}: nothing to change")
        clean[num] = entry
    if errors:
        return _render(_plan(False, "", reason="; ".join(errors)),
                       mode, confirm, host, port)
    if not clean:
        return _render(_plan(False, "", reason="no piles given"),
                       mode, confirm, host, port)

    # 2. Read the live config so the plan shows before -> after.
    data = fetch_stockpile_config(host=host, port=port)
    if not data.get("fort_loaded"):
        return _render(_plan(False, "", reason="no fortress is loaded"),
                       mode, confirm, host, port)
    live = {s.get("number"): s for s in (data.get("stockpiles") or [])}
    missing = sorted(n for n in clean if n not in live)
    if missing:
        return _render(_plan(False, "", reason="no stockpile numbered "
                       + ", ".join(f"#{n}" for n in missing)),
                       mode, confirm, host, port)

    changes, payload = [], []
    for num in sorted(clean):
        sp, e = live[num], clean[num]
        p = sp.get("pos") or {}
        name = sp.get("name") or "(unnamed)"
        head = f"#{num} {name}" + (f" [z{p['z']}]" if "z" in p else "")
        parts = []
        if "furniture_types" in e:
            parts.append(f"{_furn_desc(sp)} -> only {', '.join(e['furniture_types'])}")
        elif "furniture_except" in e:
            parts.append(f"{_furn_desc(sp)} -> all furniture types except "
                         f"{', '.join(e['furniture_except'])}")
        elif "untick_types" in e:
            parts.append(f"{_furn_desc(sp)} -> untick {', '.join(e['untick_types'])}")
        elif "disable_furniture" in e:
            parts.append(f"{_furn_desc(sp)} -> Furniture off")
        if "finished_goods_types" in e:
            now = "on" if "finished_goods" in (sp.get("accepts") or []) else "off"
            parts.append(f"Finished goods ({now}) -> only "
                         f"{', '.join(e['finished_goods_types'])}")
        if "finished_goods_materials" in e:
            ex = e.get("finished_goods_materials_except")
            parts.append("finished goods materials -> only "
                         + ", ".join(e["finished_goods_materials"])
                         + (f" except {', '.join(ex)}" if ex else ""))
        if "finished_goods_other_materials" in e:
            parts.append("wood/bone/glass/other materials -> "
                         + ("on" if e["finished_goods_other_materials"] else "off"))
        if "coin_materials" in e:
            now = "on" if "coins" in (sp.get("accepts") or []) else "off"
            parts.append(f"Coins ({now}) -> only {', '.join(e['coin_materials'])}")
        if "min_quality" in e:
            parts.append(f"quality -> {e['min_quality']} and better")
        for cap in _CAP_KEYS:
            if cap in e:
                parts.append(f"{cap[4:]} {sp.get(cap)} -> {e[cap]}")
        others = [c for c in (sp.get("accepts") or [])
                  if c != "furniture"
                  and not ("finished_goods_types" in e and c == "finished_goods")
                  and not ("coin_materials" in e and c == "coins")]
        if others:
            parts.append(f"(other categories left as is: {', '.join(others)})")
        changes.append(f"{head}: " + "; ".join(parts))
        payload.append({"number": num, "expect_name": sp.get("name") or "", **e})

    plan = _plan(
        True, f"Update Furniture types / container caps on {len(payload)} "
        "stockpile(s).",
        facts=[f"{len(payload)} of {len(live)} stockpiles would change"],
        changes=changes,
        advice=["In-game: select the stockpile -> settings -> Furniture to tick "
                "or untick types; the bin / barrel / wheelbarrow limits are on "
                "the same panel. The Steam build may reset those limits when you "
                "press Custom, so set them last."],
        action_script="set_stockpile_settings.lua",
        action_payload={"piles": payload},
        render_result=_format_settings_result,
    )
    return _render(plan, mode, confirm, host, port)


# --- 6 (original). set_hospital_supplies ------------------------------------

def set_hospital_supplies(supplies, hospital="", mode="advise", confirm=False,
                          host="127.0.0.1", port=5000):
    """Set an existing hospital location's desired-supply maximums (reversible).
    `supplies` maps any of zones.HOSPITAL_SUPPLY_FIELDS to a non-negative integer
    maximum in WHOLE ITEMS (as shown on the in-game hospital screen and reported
    by zones_intel.lua); the Lua converts to/from DF's internal dimension units.
    `hospital` selects by name substring when more than one exists."""
    from zones import HOSPITAL_SUPPLY_FIELDS, fetch_zones_intel

    # 1. Validate inputs python-side for friendly messages (the Lua revalidates).
    errors, clean = [], {}
    for k, v in (supplies or {}).items():
        if k not in HOSPITAL_SUPPLY_FIELDS:
            errors.append(f"unknown supply '{k}'")
            continue
        try:
            n = int(v)
        except (TypeError, ValueError):
            errors.append(f"{k}: not an integer ({v!r})")
            continue
        if n < 0:
            errors.append(f"{k}: must be >= 0")
            continue
        clean[k] = n
    if errors:
        return _render(_plan(False, "", reason="; ".join(errors)),
                       mode, confirm, host, port)
    if not clean:
        return _render(_plan(False, "", reason="no valid supplies to set "
                       f"(allowed: {'/'.join(HOSPITAL_SUPPLY_FIELDS)})"),
                       mode, confirm, host, port)

    # 2. Read live state to resolve the hospital and show old -> new values.
    data = fetch_zones_intel(host=host, port=port)
    if not data.get("fort_loaded"):
        return _render(_plan(False, "", reason="no fortress is loaded"),
                       mode, confirm, host, port)
    hosps = [as_map(l) for l in (data.get("locations") or [])
             if as_map(l).get("hospital")]
    if not hosps:
        return _render(_plan(False, "", reason="no hospital exists on this site; "
                       "designate one in-game first"), mode, confirm, host, port)
    if hospital:
        hosps = [l for l in hosps
                 if hospital.lower() in str(l.get("name", "")).lower()]
        if not hosps:
            return _render(_plan(False, "", reason=f"no hospital matches "
                           f"name {hospital!r}"), mode, confirm, host, port)
        if len(hosps) > 1:
            return _render(_plan(False, "", reason=f"{len(hosps)} hospitals match "
                           f"{hospital!r}; be more specific"),
                           mode, confirm, host, port)
    elif len(hosps) > 1:
        names = ", ".join(str(l.get("name")) for l in hosps)
        return _render(_plan(False, "", reason=f"{len(hosps)} hospitals exist "
                       f"({names}); pass hospital=<name substr>"),
                       mode, confirm, host, port)
    target = hosps[0]
    hmap = as_map(target.get("hospital"))

    facts = [f"hospital: {target.get('name', '?')}"]
    changes = []
    for k, n in clean.items():
        cur = as_map(hmap.get(k))
        old = cur.get("max", "?")
        facts.append(f"{k}: max {old} -> {n} (stocked now: {cur.get('have', '?')})")
        changes.append(f"{k} max: {old} -> {n}")

    plan = _plan(
        True,
        f"Set hospital supply maximum(s) on '{target.get('name', '?')}': "
        + ", ".join(f"{k}={n}" for k, n in clean.items()) + ".",
        facts=facts, changes=changes,
        advice=["In-game: open the hospital under Locations and set the supply "
                f"maximums ({'/'.join(clean)}) to the values above."],
        action_script="set_hospital_supplies.lua",
        action_payload={"hospital": hospital or "", "supplies": clean},
        render_result=_format_zone_result,
    )
    return _render(plan, mode, confirm, host, port)
