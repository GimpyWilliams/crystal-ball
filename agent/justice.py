"""
READ-ONLY intel for the justice subsystem: law-enforcement positions
(sheriff / captain of the guard) and logged crimes. One bundled, audited Lua
query per function through DFHack's RunCommand RPC; nothing here changes state.
"""

from intel import as_map, run_intel
from reports import append_errors, format_diagnosis


def fetch_justice_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("justice_intel.lua", host=host, port=port)


def format_justice_report(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    lines = ["=== Justice Report ==="]

    positions = data.get("law_enforcement") or []
    lines.append("\nLaw-enforcement positions:")
    if positions:
        for p in positions:
            cap = p.get("capacity", 0)
            cap_s = "unlimited" if cap == -1 else cap
            status = "FILLED" if p.get("assigned", 0) > 0 else "VACANT"
            lines.append(f"  {p.get('name', '?')}: {p.get('assigned', 0)}/{cap_s} "
                         f"[{status}]")
    else:
        lines.append("  (none defined)")

    lines.append(f"\nCrimes logged: {data.get('crimes_logged', 0)}")

    append_errors(lines, data)
    return "\n".join(lines)


def fetch_justice_diagnosis(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("diagnose_justice.lua", host=host, port=port)


_JUSTICE_LABELS = {
    "law_position_exists": "Law-enforcement position defined",
    "law_officer_assigned": "A law officer is appointed",
    "crime_caseload": "No outstanding crimes",
}


def format_justice_diagnosis(data: dict) -> str:
    return format_diagnosis(
        data, "=== Is fortress justice functioning? ===", _JUSTICE_LABELS,
        ("law_positions", "law_filled", "crimes_logged"),
        "a law officer is appointed, so crimes can be investigated and punished "
        "(if punishments still stall, check for a built jail with chains/cages)")
