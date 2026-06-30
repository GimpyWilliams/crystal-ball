"""
READ-ONLY fort "morning briefing": one batched roll-up of the things you want to
see when you load the game -- citizen/stress summary, strange moods, hospital,
workshops, key survival stocks, and a cross-industry roll-up of flagged blockers.

The whole briefing runs inside a single shared_connection(), so the ~16 audited
read queries it fans out to reuse ONE DFHack socket + handshake instead of
opening one apiece. Nothing here changes game state; it only composes existing
read queries.
"""

from intel import as_map, shared_connection
from dwarves import fetch_roster
from mood import fetch_mood
from medical import fetch_medical_intel
from pipelines import fetch_shops_and_orders, fetch_stock
from diagnostics import fetch_brewing_diagnosis
from food import (
    fetch_butchery_diagnosis,
    fetch_cooking_diagnosis,
    fetch_farming_diagnosis,
    fetch_fishing_diagnosis,
)
from textiles import fetch_textiles_diagnosis
from metalworks import fetch_fuel_diagnosis, fetch_metal_diagnosis
from construction import fetch_construction_diagnosis
from medical import fetch_medical_diagnosis
from justice import fetch_justice_diagnosis

# (industry label, diagnosis fetcher). Order = the order blockers are listed.
_DIAGNOSES = [
    ("brewing", fetch_brewing_diagnosis),
    ("cooking", fetch_cooking_diagnosis),
    ("farming", fetch_farming_diagnosis),
    ("fishing", fetch_fishing_diagnosis),
    ("butchery", fetch_butchery_diagnosis),
    ("textiles", fetch_textiles_diagnosis),
    ("metal", fetch_metal_diagnosis),
    ("fuel", fetch_fuel_diagnosis),
    ("construction", fetch_construction_diagnosis),
    ("medical", fetch_medical_diagnosis),
    ("justice", fetch_justice_diagnosis),
]

# Survival/operations stocks worth a headline glance, in display order. Only
# those actually present as item-type categories are shown.
_KEY_STOCKS = ["DRINK", "FOOD", "MEAT", "FISH", "PLANT", "SEEDS",
               "WOOD", "BOULDER", "BAR", "CLOTH"]

# Stress threshold mirroring dwarves._stress_word: >= this is "stressed".
_STRESS_LIMIT = 25000


def fetch_briefing(host: str = "127.0.0.1", port: int = 5000) -> dict:
    """Fan out every briefing section over ONE shared DFHack connection. Each
    industry diagnosis is isolated: if one query fails, it is recorded in
    `section_errors` and the rest of the briefing still renders."""
    out: dict = {"fort_loaded": False, "section_errors": []}
    with shared_connection(host, port):
        roster = _safe(out, "roster", fetch_roster)
        out["fort_loaded"] = bool(roster.get("fort_loaded"))
        if not out["fort_loaded"]:
            return out
        out["roster"] = roster
        out["moods"] = _safe(out, "moods", fetch_mood)
        out["medical"] = _safe(out, "medical", fetch_medical_intel)
        out["shops"] = _safe(out, "shops", fetch_shops_and_orders)
        out["stock"] = _safe(out, "stock", fetch_stock)

        blockers = []
        for industry, fetch in _DIAGNOSES:
            data = _safe(out, f"diagnose_{industry}", fetch)
            for c in (data.get("checks") or []):
                if c.get("severity") == "blocker" and c.get("ok") is False:
                    blockers.append({"industry": industry,
                                     "name": c.get("name", ""),
                                     "detail": c.get("detail", "")})
        out["blockers"] = blockers
    return out


def _safe(out: dict, label: str, fetch) -> dict:
    """Run one section fetch; on failure record it and return {} so the rest of
    the briefing still composes."""
    try:
        return fetch()
    except Exception as e:  # noqa: BLE001 -- one bad section must not sink all
        out["section_errors"].append(f"{label}: {e}")
        return {}


def format_briefing(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    lines = ["=== Fort Briefing ==="]
    lines.append(_citizens_line(data))
    lines += _moods_block(data)
    lines.append(_hospital_line(data))
    lines.append(_workshops_line(data))
    lines += _stocks_block(data)
    lines += _blockers_block(data)

    errs = data.get("section_errors") or []
    if errs:
        lines.append("\nNote -- some sections could not be read:")
        lines += [f"  - {e}" for e in errs]
    return "\n".join(lines)


def _citizens_line(data: dict) -> str:
    dwarves = as_map(data.get("roster")).get("dwarves") or []
    count = as_map(data.get("roster")).get("count", len(dwarves))
    idle = sum(1 for d in dwarves if d.get("activity") == "Idle")
    stressed = sum(1 for d in dwarves if (d.get("stress") or 0) >= _STRESS_LIMIT)
    wounded = sum(1 for d in dwarves if d.get("wounded"))
    moody = sum(1 for d in dwarves
                if d.get("mood") and d.get("mood") != "none")
    return (f"\nCitizens: {count}  ({idle} idle, {stressed} stressed, "
            f"{wounded} wounded, {moody} in mood)")


def _moods_block(data: dict) -> list:
    moods = as_map(data.get("moods")).get("moods") or []
    if not moods:
        return ["Strange moods: none."]
    lines = [f"\nStrange moods ({len(moods)}):"]
    for m in moods:
        who = f"{m.get('name', '?')} ({m.get('mood', '?')})"
        if m.get("insane"):
            lines.append(f"  [!] {who} -- ALREADY INSANE, lost.")
        elif m.get("blocked_count") and m.get("productive"):
            lines.append(f"  [!] {who} -- {m['blocked_count']} requirement(s) "
                         "BLOCKED, insanity risk.")
        else:
            lines.append(f"  [ ] {who} -- gathering / satisfiable.")
    return lines


def _hospital_line(data: dict) -> str:
    med = as_map(data.get("medical"))
    wounded = med.get("wounded", 0)
    hosp = med.get("hospitals", 0)
    cg = as_map(med.get("caregivers"))
    line = (f"\nHospital: {wounded} needing care; {hosp} hospital zone(s); "
            f"caregivers dx={cg.get('diagnose', 0)} surg={cg.get('surgery', 0)} "
            f"bone={cg.get('bone_setting', 0)} suture={cg.get('suturing', 0)} "
            f"dress={cg.get('dressing_wounds', 0)}")
    if wounded and not cg.get("diagnose"):
        line += "  [!] wounded but no diagnostician"
    return line


def _workshops_line(data: dict) -> str:
    shops = as_map(as_map(data.get("shops")).get("workshops"))
    built = sum(s.get("count", 0) for s in shops.values())
    idle = sum(s.get("idle", 0) for s in shops.values())
    busy = sum(s.get("busy", 0) for s in shops.values())
    orders = as_map(data.get("shops")).get("orders") or []
    active = sum(1 for o in orders if o.get("active") is not False)
    return (f"\nWorkshops: {built} built ({idle} idle, {busy} busy); "
            f"{active}/{len(orders)} manager order(s) active")


def _stocks_block(data: dict) -> list:
    cats = as_map(as_map(data.get("stock")).get("categories"))
    lines = ["\nKey stocks (available now):"]
    shown = False
    for tname in _KEY_STOCKS:
        c = cats.get(tname)
        if not c:
            continue
        shown = True
        avail = c.get("available", c.get("free_units", 0))
        flag = "  [!] none available" if avail == 0 else ""
        lines.append(f"  {avail:>6}  {tname}{flag}")
    if not shown:
        lines.append("  (no tracked stock categories present)")
    return lines


def _blockers_block(data: dict) -> list:
    blockers = data.get("blockers") or []
    if not blockers:
        return ["\nIndustry blockers: none flagged across industries."]
    lines = [f"\nIndustry blockers ({len(blockers)} flagged):"]
    for b in blockers:
        detail = b.get("detail") or b.get("name") or "blocked"
        lines.append(f"  [{b['industry']}] {detail}")
    return lines
