"""
Shared plain-text rendering helpers for the industry report/diagnose modules
(food.py, textiles.py, metalworks.py, ...). READ-ONLY: pure formatting of data
already fetched; nothing here touches the game or the RPC.
"""

from intel import as_map

# How each owned-but-locked state reads inside the on-hand breakdown.
_OWNED_REASON_LABELS = {
    "forbidden": "forbidden",
    "dumped": "marked for dumping",
    "claimed_job": "reserved by jobs",
    "carried": "carried by dwarves",
    "melt": "queued to melt",
}

# Not-yet-acquired states: (display name, how-to-realize hint). These are NOT
# owned by the fort -- they must never be folded into an on-hand/stock figure.
_UNOWNED_REASON = {
    "uncollected_web": ("uncollected webs", "collect webs / weave to realize these"),
    "loose_unreachable": ("unreachable on the map", "dig or build a path to reach them"),
    "trade": ("at the trade depot (caravan's)", "buy them from the caravan"),
}


def _on_hand_breakdown(st: dict) -> list:
    """The non-zero sub-states that make up on_hand, in reading order."""
    parts = []
    if st.get("available"):
        parts.append(f"{st['available']} available")
    if st.get("in_transit"):
        parts.append(f"{st['in_transit']} in transit")
    for reason, n in sorted(as_map(st.get("by_reason_owned")).items(),
                            key=lambda kv: -kv[1]):
        parts.append(f"{n} {_OWNED_REASON_LABELS.get(reason, reason)}")
    if st.get("inert"):
        parts.append(f"{st['inert']} built-in/rotten")
    return parts


def _mat_block(mats: dict, top: int, indent: str = "    ") -> list:
    """Per-material lines for one section, biggest first, capped at `top`."""
    out = []
    items = sorted(as_map(mats).items(), key=lambda kv: -kv[1])
    for mat, n in items[:top]:
        out.append(f"{indent}{n:>6}  {mat}")
    if len(items) > top:
        out.append(f"{indent}... and {len(items) - top} more materials")
    return out


def _not_yet_acquired_lines(st: dict, indent: str = "  ") -> list:
    """Render the not-yet-acquired section, or [] when there's nothing potential.
    Owned, locked stock is NEVER shown here -- only genuinely un-owned items."""
    total = st.get("not_yet_acquired", 0)
    if not total:
        return []
    reasons = sorted(as_map(st.get("by_reason_unowned")).items(),
                     key=lambda kv: -kv[1])
    lines = []
    if len(reasons) == 1:
        reason, _ = reasons[0]
        display, hint = _UNOWNED_REASON.get(reason, (reason, ""))
        lines.append(f"Not yet acquired: {total}  ({display})")
        if hint:
            lines.append(f"{indent}-> {hint}")
    else:
        lines.append(f"Not yet acquired: {total}")
        for reason, n in reasons:
            display, hint = _UNOWNED_REASON.get(reason, (reason, ""))
            tail = f" -> {hint}" if hint else ""
            lines.append(f"{indent}{n} {display}{tail}")
    return lines


def stock_line(label: str, st: dict, top_materials: int = 0) -> str:
    """Honest stock block from a stock_states() result, leading with what the
    fort OWNS (on hand) and listing not-yet-acquired (uncollected webs / trade
    goods / unreachable) as a SEPARATE figure -- never folded into the on-hand
    number. When top_materials > 0, the per-material breakdown is nested WITHIN
    each section (on-hand materials under on-hand, unowned under not-yet-acquired)
    so owned and unowned materials are never blurred. Returns a multi-line
    string. Tolerates the older {free_units,total_units} shape for un-migrated
    callers."""
    if "on_hand" not in st:  # legacy shape -- best-effort single line
        avail = st.get("available", st.get("free_units", 0))
        total = st.get("total", st.get("total_units", 0))
        return f"{label}: {avail} available / {total} total"

    on_hand = st.get("on_hand", 0)
    lines = [f"{label} (on hand): {on_hand}"]
    parts = _on_hand_breakdown(st)
    if parts:
        lines.append("  " + ", ".join(parts))
    elif on_hand == 0:
        lines.append("  (none on hand)")
    if top_materials:
        lines += _mat_block(st.get("by_material_on_hand"), top_materials)
    nay = _not_yet_acquired_lines(st)
    if nay:
        lines += nay
        if top_materials:
            lines += _mat_block(st.get("by_material_unowned"), top_materials)
    return "\n".join(lines)


def append_errors(lines: list, data: dict,
                  what: str = "some sections could not be read") -> None:
    """Append the report's `errors` list (if any) as a trailing note."""
    errs = data.get("errors") or []
    if errs:
        lines.append(f"\nNote -- {what}:")
        for e in errs:
            lines.append(f"  - {e}")


def format_diagnosis(data: dict, title: str, labels: dict,
                     fact_keys: tuple, none_blocker_hint: str) -> str:
    """Shared renderer for the diagnose_* pipelines (same shape as brewing):
    ranked blockers, un-evaluable checks, the full checklist, then facts.

    `labels` maps a check name to a human label; `fact_keys` is the ordered set
    of facts to print; `none_blocker_hint` finishes the "no blocker found"
    sentence."""
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."

    checks = data.get("checks") or []
    facts = as_map(data.get("facts"))

    blockers = [c for c in checks if c.get("severity") == "blocker"
                and c.get("ok") is False]
    unknown = [c for c in checks if c.get("ok") is None]

    def lbl(name):
        return labels.get(name, name)

    lines = [title]

    if blockers:
        lines.append(f"\nLikely blockers ({len(blockers)}):")
        for c in blockers:
            lines.append(f"  [X] {lbl(c['name'])}: {c.get('detail', '')}")
    else:
        lines.append(f"\nNo hard blocker found. Every prerequisite below is "
                     f"satisfied, so {none_blocker_hint}.")

    if unknown:
        lines.append("\nCould not evaluate (check manually):")
        for c in unknown:
            lines.append(f"  [?] {lbl(c['name'])}: {c.get('detail', '')}")

    lines.append("\nPipeline checklist:")
    for c in checks:
        mark = {True: "ok ", False: "XX ", None: "?? "}[c.get("ok")]
        lines.append(f"  {mark}{lbl(c['name'])}: {c.get('detail', '')}")

    lines.append("\nFacts:")
    for k in fact_keys:
        if k in facts:
            lines.append(f"  {k} = {facts[k]}")

    append_errors(lines, data, "some checks could not be read")
    return "\n".join(lines)
