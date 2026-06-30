"""
READ-ONLY diplomatic agreements and entity relations for crystal-ball.

Queries df.global.world.diplomacy (anger, relation flags per entity) and
df.global.world.agreements (if accessible on this DFHack version) via
world_agreements_intel.lua. The probe section in every response shows which
struct paths were accessible, making version-specific failures self-diagnosing.
"""

from intel import as_map, run_intel
from reports import append_errors


def fetch_agreements_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("world_agreements_intel.lua", host=host, port=port)


def format_agreements_report(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    lines = ["=== Diplomatic Agreements & Entity Relations ==="]

    # Probe summary — always shown so the caller knows what struct paths worked.
    probe = as_map(data.get("probe"))
    probe_lines = []
    if probe.get("diplomacy_error"):
        probe_lines.append(
            f"  world.diplomacy: ERROR — {probe['diplomacy_error']}")
    elif "diplomacy_entity_count" in probe:
        probe_lines.append(
            f"  world.diplomacy: {probe['diplomacy_entity_count']} entities")
    if probe.get("agreements_error"):
        probe_lines.append(
            f"  world.agreements: not accessible — {probe['agreements_error']}")
    elif "agreements_count" in probe:
        probe_lines.append(
            f"  world.agreements: {probe['agreements_count']} records")
    if probe_lines:
        lines.append("\nStruct paths:")
        lines.extend(probe_lines)

    # Formal agreements (world.agreements, if accessible)
    agreements = data.get("agreements") or []
    if agreements:
        lines.append(f"\nFormal agreements: {len(agreements)}")
        for a in agreements:
            parties  = a.get("party_ids") or []
            type_raw = a.get("type_raw", "")
            party_str = ", ".join(str(p) for p in parties) if parties else "?"
            lines.append(
                f"  #{a.get('id', '?')}  parties={party_str}"
                + (f"  [{type_raw}]" if type_raw else ""))

    # Liaison meetings (plotinfo.dip_meeting_info)
    entities = data.get("diplomacy_entities") or []
    if entities:
        lines.append(f"\nActive liaison meeting{'s' if len(entities) > 1 else ''}:")
        for e in entities:
            civ    = e.get("civ_name") or f"entity#{e.get('civ_id', '?')}"
            ctype  = e.get("civ_type", "")
            dipl   = e.get("diplomat_name") or f"hf#{e.get('diplomat_id', '?')}"
            step   = e.get("cur_step", -1)
            evts   = e.get("events_count", 0)
            evlist = e.get("events") or []
            lines.append(f"  {dipl} from {civ} ({ctype})")
            lines.append(f"    cur_step={step}  events={evts}")
            for ev in evlist:
                lines.append(f"    event: type={ev.get('type')}  year={ev.get('year')}")
    else:
        lines.append("\nNo active liaison meetings.")

    if not agreements and not entities:
        lines.append(
            "\nNote: no diplomatic data found via either world.agreements "
            "or plotinfo.dip_meeting_info. Check the probe section above.")

    append_errors(lines, data)
    return "\n".join(lines)
