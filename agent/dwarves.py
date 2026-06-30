"""
READ-ONLY dwarf diagnostics: a roster of all citizens, a deep profile of one
dwarf, and labor coverage ("who can do X"). Each runs one bundled, audited Lua
query (scripts/dwarf_*.lua, scripts/labor_coverage.lua). The selector/labor
arguments are forwarded as DATA only -- never executed. Nothing changes state.
"""

from intel import as_map, run_intel


# --- roster ----------------------------------------------------------------

def fetch_roster(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("dwarf_roster.lua", host=host, port=port)


def _stress_word(stress) -> str:
    # Lower stress is better in DF. Coarse bands; numbers are approximate.
    if stress is None:
        return "?"
    if stress < 0:
        return "happy"
    if stress < 25000:
        return "ok"
    if stress < 50000:
        return "stressed"
    return "miserable"


def format_roster(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."

    dwarves = data.get("dwarves") or []
    lines = [f"=== Citizen Roster ({data.get('count', 0)} citizens) ==="]
    # Most-stressed and idle first -- those are who you usually care about.
    dwarves = sorted(
        dwarves,
        key=lambda d: (d.get("activity") != "Idle", -(d.get("stress") or 0)),
    )
    for d in dwarves:
        flags = []
        if d.get("unmet_needs"):
            flags.append(f"{d['unmet_needs']} unmet need(s)")
        if d.get("wounded"):
            flags.append("wounded")
        if d.get("mood") and d["mood"] != "none":
            flags.append(f"mood:{d['mood']}")
        flag_note = f"  [{', '.join(flags)}]" if flags else ""
        species = d.get("species")
        species_tag = f" [{species.title()}]" if species and species != "DWARF" else ""
        lines.append(
            f"  #{d.get('id')}  {d.get('name', '?')}{species_tag} "
            f"({d.get('profession', '?')}) -- {d.get('activity', '?')}; "
            f"{_stress_word(d.get('stress'))}{flag_note}"
        )
    _append_errors(lines, data)
    return "\n".join(lines)


# --- single-dwarf detail ---------------------------------------------------

def fetch_dwarf_detail(selector: str, host: str = "127.0.0.1",
                       port: int = 5000) -> dict:
    return run_intel("dwarf_detail.lua", [str(selector)], host=host, port=port)


def format_dwarf_detail(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."

    if data.get("need_selection"):
        lines = [data.get("message", "Pick a dwarf:")]
        for c in (data.get("candidates") or []):
            lines.append(f"  #{c.get('id')}  {c.get('name', '?')} "
                         f"({c.get('profession', '?')})")
        return "\n".join(lines)

    d = as_map(data.get("dwarf"))
    if not d:
        return "No dwarf data returned."

    lines = [f"=== {d.get('name', '?')} (#{d.get('id')}) ===",
             f"Profession: {d.get('profession', '?')}   Sex: {d.get('sex', '?')}"
             f"   Species: {d.get('species', '?')}"]
    pos = as_map(d.get("position"))
    if pos:
        lines.append(f"At: ({pos.get('x')}, {pos.get('y')}, {pos.get('z')})")
    lines.append(f"Doing: {d.get('current_job', '?')}"
                 + ("  (SUSPENDED)" if d.get("job_suspended") else ""))
    lines.append(f"Stress: {d.get('stress')} ({_stress_word(d.get('stress'))})"
                 f"   Mood: {d.get('mood', 'none')}")

    needs = d.get("needs") or []
    unmet = [n for n in needs if (n.get("focus_level") or 0) < 0]
    if unmet:
        lines.append(f"\nUnmet needs ({len(unmet)}):")
        for n in sorted(unmet, key=lambda n: n.get("focus_level", 0)):
            lines.append(f"  {n.get('need', '?')}  (focus {n.get('focus_level')})")

    th = d.get("recent_thoughts") or []
    if th:
        lines.append("\nRecent thoughts:")
        for t in th:
            lines.append(f"  {t.get('emotion', '?')} -- {t.get('thought', '?')} "
                         f"(strength {t.get('strength')})")

    health = as_map(d.get("health"))
    if health:
        parts = [f"wounds={health.get('wounds', 0)}"]
        for k in ("hunger_timer", "thirst_timer", "sleepiness_timer"):
            if k in health:
                parts.append(f"{k}={health[k]}")
        lines.append("\nHealth: " + ", ".join(parts))

    skills = d.get("skills") or []
    if skills:
        top = [s for s in skills if (s.get("level") or 0) > 0][:12]
        lines.append("\nTop skills:")
        for s in top:
            lines.append(f"  {s.get('skill', '?')}: level {s.get('level')}")

    labors = d.get("labors_enabled") or []
    if labors:
        lines.append(f"\nLabors enabled ({len(labors)}): " + ", ".join(labors))

    _append_errors(lines, data)
    return "\n".join(lines)


# --- labor coverage --------------------------------------------------------

def fetch_labor_coverage(labor: str = "BREWER", host: str = "127.0.0.1",
                         port: int = 5000) -> dict:
    return run_intel("labor_coverage.lua", [str(labor)], host=host, port=port)


def format_labor_coverage(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."
    if data.get("error"):
        return data["error"]

    labor = data.get("labor", "?")
    workers = data.get("workers") or []
    lines = [f"=== Labor coverage: {labor} ===",
             f"{data.get('enabled_count', 0)} of "
             f"{data.get('citizens_total', 0)} citizens have it enabled"]

    if workers:
        for w in sorted(workers, key=lambda w: (w.get("busy", False),
                                                -(w.get("stress") or 0))):
            state = "busy" if w.get("busy") else "idle"
            lines.append(f"  #{w.get('id')}  {w.get('name', '?')} -- {state}, "
                         f"{_stress_word(w.get('stress'))}")
    else:
        lines.append("  (nobody has this labor enabled)")

    details = data.get("work_details")
    if details is not None:
        if details:
            lines.append("\nWork details governing this labor:")
            for wd in details:
                lines.append(f"  {wd.get('name', '?')}: "
                             f"{wd.get('assigned_units', 0)} assigned")
        else:
            lines.append("\nNo work detail restricts this labor "
                         "(any able citizen does it by default).")

    _append_errors(lines, data)
    return "\n".join(lines)


# --- bedroom assignments ---------------------------------------------------

def fetch_bedroom_assignments(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("bedroom_intel.lua", host=host, port=port)


def format_bedroom_assignments(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."

    total_beds = data.get("total_beds", 0)
    total_zones = data.get("total_bedroom_zones", total_beds)
    unowned = data.get("unowned_beds", 0)
    total_citizens = data.get("total_citizens", 0)
    unhoused = data.get("citizens_without_beds") or []
    housed = total_citizens - len(unhoused)

    lines = [
        "=== Bedroom Assignments ===",
        f"{total_beds} beds  |  {total_zones} zones  |  {housed}/{total_citizens} citizens housed  |  {unowned} zones unclaimed",
    ]

    if unhoused:
        lines.append(f"\nCitizens without a bedroom ({len(unhoused)}):")
        for c in unhoused:
            lines.append(f"  #{c.get('id')}  {c.get('name', '?')}")
    else:
        lines.append("\nAll citizens have a bedroom assigned.")

    unowned_beds = [b for b in (data.get("beds") or []) if not b.get("owner_id")]
    if unowned_beds:
        lines.append(f"\nUnclaimed bedroom zones ({len(unowned_beds)}):")
        for b in unowned_beds:
            pos = b.get("pos") or {}
            lines.append(f"  z={pos.get('z')}  ({pos.get('x')}, {pos.get('y')})")

    _append_errors(lines, data)
    return "\n".join(lines)


# --- shared ----------------------------------------------------------------

def _append_errors(lines: list, data: dict) -> None:
    errs = data.get("errors") or []
    if errs:
        lines.append("\nNote -- some sections could not be read:")
        for e in errs:
            lines.append(f"  - {e}")
