"""
READ-ONLY intel for the hospital / medical subsystem: hospital zones, wounded
citizens, caregiver labor coverage, and supplies. One bundled, audited Lua query
per function through DFHack's RunCommand RPC; nothing here changes game state.
"""

from intel import as_map, run_intel
from reports import append_errors, format_diagnosis


def fetch_medical_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("medical_intel.lua", host=host, port=port)


def format_medical_report(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    lines = ["=== Hospital / Medical Report ==="]

    lines.append(f"\nHospital zones: {data.get('hospitals', 0)}")
    lines.append(f"Citizens needing healthcare: {data.get('wounded', 0)}")

    cg = as_map(data.get("caregivers"))
    lines.append("\nCaregiver coverage (citizens with the labor enabled):")
    for key, label in (("diagnose", "diagnosis"), ("surgery", "surgery"),
                       ("bone_setting", "bone-setting"), ("suturing", "suturing"),
                       ("dressing_wounds", "wound-dressing")):
        lines.append(f"  {cg.get(key, 0):>3}  {label}")

    sup = as_map(data.get("supplies"))
    lines.append("\nSupplies available fort-wide (free/total) "
                 "— see zones_report for what is actually stocked in the hospital:")
    for key, label in (("splints", "splints"), ("crutches", "crutches"),
                       ("cloth", "cloth"), ("thread", "thread"),
                       ("buckets", "buckets")):
        s = as_map(sup.get(key))
        lines.append(f"  {label}: {s.get('free_units', 0)}/{s.get('total_units', 0)}")

    append_errors(lines, data)
    return "\n".join(lines)


def fetch_medical_diagnosis(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("diagnose_medical.lua", host=host, port=port)


_MEDICAL_LABELS = {
    "wounded_present": "No untreated wounded",
    "hospital_exists": "Hospital zone defined",
    "diagnostician_assigned": "A dwarf can diagnose",
    "surgeon": "A dwarf can do surgery",
    "bone_doctor": "A dwarf can set bones",
    "suturer": "A dwarf can suture",
    "wound_dresser": "A dwarf can dress wounds",
    "supplies_on_hand": "Medical supplies on hand",
}


def format_medical_diagnosis(data: dict) -> str:
    return format_diagnosis(
        data, "=== Can the wounded be treated? ===", _MEDICAL_LABELS,
        ("wounded", "hospitals", "splints", "crutches", "cloth", "buckets"),
        "the fort has a hospital and caregivers, so care should proceed (a stuck "
        "patient is usually a missing specific treatment labor, no water source, "
        "or no free hospital bed)")
