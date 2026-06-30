"""
READ-ONLY strange-mood report. Runs scripts/mood_intel.lua, which finds every
citizen in a mood and, for the productive ones, reads what their claimed workshop
job still demands -- cross-referenced against on-hand stock so each requirement
shows as satisfiable, blocked, or "exists but stuck".

A productive mood (fey/secretive/possessed/macabre/fell) whose materials never
arrive ends in PERMANENT insanity, so this report leads with any blocked
requirement and an explicit risk line. Nothing here changes game state.
"""

from intel import as_map, run_intel


def fetch_mood(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("mood_intel.lua", host=host, port=port)


# Plain-language names for the unowned states a needed material can be stuck in.
_STUCK_HINT = {
    "uncollected_web": "only as uncollected webs (collect/weave to realize)",
    "loose_unreachable": "behind no walkable path (dig/build to reach)",
    "trade": "at the trade depot (buy from the caravan)",
}


def _req_line(r: dict) -> list[str]:
    """Render one requirement as a marked line plus optional stock context."""
    need = r.get("qty_needed", 1)
    got = r.get("qty_filled", 0)
    sat = r.get("satisfiable")
    mark = {True: "[ok]", False: "[XX]", None: "[? ]"}[sat]
    want = f"{r.get('item_type', '?')} ({r.get('material', 'any')})"

    out = [f"    {mark} wants {want}  x{need}" + (f" (have {got})" if got else "")]
    if got >= need:
        return out  # already attached; no stock context needed

    avail = r.get("available")
    if avail is not None:
        parts = [f"{avail} available"]
        if r.get("locked"):
            parts.append(f"{r['locked']} owned-but-locked")
        if r.get("unowned"):
            parts.append(f"{r['unowned']} not-yet-acquired")
        out.append("        on hand: " + ", ".join(parts))

        mats = r.get("by_material_available") or []
        if mats:
            out.append("        available by material: "
                       + ", ".join(f"{m['units']} {m['material']}" for m in mats))

        # Spell out where the un-acquired stock is stuck -- this is usually the
        # whole story (e.g. "silk exists, but only as uncollected webs").
        for st, n in (as_map(r.get("unowned_by_state"))).items():
            out.append(f"        -> {n} {_STUCK_HINT.get(st, st)}")
    return out


def format_mood(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."

    moods = data.get("moods") or []
    lines = [f"=== Strange Moods ({len(moods)} active) ==="]

    if not moods:
        lines.append("\nNo dwarf is currently in a mood. ✓")
        _append_errors(lines, data)
        return "\n".join(lines)

    for m in moods:
        lines.append("")
        header = (f"  {m.get('name', '?')} ({m.get('profession', '?')}) "
                  f"-- {m.get('mood', '?')} mood")
        if m.get("workshop"):
            header += f" @ {m['workshop']}"
        lines.append(header)

        if m.get("insane"):
            lines.append("    ⚠️  ALREADY INSANE -- no artifact will come of this; "
                         "this dwarf is lost.")
            continue

        if m.get("job") == "none yet" or (m.get("gathering") and
                                          not m.get("requirements")):
            lines.append("    Claimed the mood but has not posted requirements yet "
                         "(still picking a workshop / gathering).")
            continue

        reqs = m.get("requirements") or []
        if not reqs:
            lines.append("    No item requirements read for the current job.")
        for r in reqs:
            lines.extend(_req_line(r))

        # Risk verdict: a productive mood with a blocked requirement is on the
        # clock toward insanity.
        blocked = m.get("blocked_count", 0)
        if blocked and m.get("productive"):
            lines.append(f"    ⚠️  {blocked} requirement(s) BLOCKED -- supply them "
                         "or this dwarf goes insane.")
        elif m.get("productive") and reqs:
            unknown = sum(1 for r in reqs if r.get("satisfiable") is None)
            if unknown:
                lines.append("    Note: some requirements couldn't be auto-checked; "
                             "verify the breakdown above.")
            else:
                lines.append("    ✓ All requirements appear satisfiable.")

    _append_errors(lines, data)
    return "\n".join(lines)


def _append_errors(lines: list, data: dict) -> None:
    errs = data.get("errors") or []
    if errs:
        lines.append("\nNote -- some units could not be read:")
        for e in errs:
            lines.append(f"  - {e}")
