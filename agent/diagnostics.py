"""
READ-ONLY root-cause diagnosis for the brewing pipeline.

Runs scripts/diagnose_brewing.lua, which gathers facts and runs deterministic
ok/not-ok checks along the pipeline. This module ranks those checks into a
plain blocker list. The deeper "what should I do about it" narration is left to
the assistant reading this output -- the script and this formatter only state
verifiable facts. Nothing here changes game state.
"""

from intel import as_map, run_intel


def fetch_brewing_diagnosis(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("diagnose_brewing.lua", host=host, port=port)


def format_brewing_diagnosis(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."

    checks = data.get("checks") or []
    facts = as_map(data.get("facts"))

    blockers = [c for c in checks if c.get("severity") == "blocker"
                and c.get("ok") is False]
    unknown = [c for c in checks if c.get("ok") is None]

    lines = ["=== Why isn't beer being made? ==="]

    if blockers:
        lines.append(f"\nLikely blockers ({len(blockers)}):")
        for c in blockers:
            lines.append(f"  [X] {_label(c['name'])}: {c.get('detail', '')}")
    else:
        lines.append("\nNo hard blocker found along the brewing pipeline. "
                     "Every prerequisite below is satisfied, so if brewing is "
                     "still stalled the cause is likely subtler (unreachable "
                     "items, a burrow/stockpile restriction, idle dwarves busy "
                     "elsewhere, or the order's conditions not yet met).")

    if unknown:
        lines.append("\nCould not evaluate (check manually):")
        for c in unknown:
            lines.append(f"  [?] {_label(c['name'])}: {c.get('detail', '')}")

    # Full checklist for transparency.
    lines.append("\nPipeline checklist:")
    for c in checks:
        mark = {True: "ok ", False: "XX ", None: "?? "}[c.get("ok")]
        lines.append(f"  {mark}{_label(c['name'])}: {c.get('detail', '')}")

    lines.append("\nFacts:")
    for k in ("brew_order_units_left", "stills", "stills_idle",
              "active_brew_jobs", "raw_plant_units_free", "empty_barrels",
              "empty_pots", "brew_work_details", "brew_work_detail_units"):
        if k in facts:
            lines.append(f"  {k} = {facts[k]}")

    errs = data.get("errors") or []
    if errs:
        lines.append("\nNote -- some checks could not be read:")
        for e in errs:
            lines.append(f"  - {e}")

    return "\n".join(lines)


_LABELS = {
    "brew_order_exists": "Brew order queued",
    "still_exists": "Still built",
    "brew_job_running": "Brew job at a still",
    "brewable_plants_available": "Brewable plants on hand",
    "empty_container_available": "Empty barrel/pot to store drink",
    "brewer_assigned": "A dwarf can/does brew",
}


def _label(name: str) -> str:
    return _LABELS.get(name, name)
