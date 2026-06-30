"""
READ-ONLY intel for the livestock industry: tame animal census by species
(sex, pregnancy, productive/ancillary traits, training level) plus breeding
diagnosis (missing mates, pen zones, nest boxes).

Each function runs one bundled, audited Lua query through DFHack's RunCommand
RPC. Nothing here changes game state.
"""

from intel import as_map, run_intel
from reports import append_errors, format_diagnosis


# ── Fetch ───────────────────────────────────────────────────────────────────

def fetch_livestock_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("livestock_intel.lua", host=host, port=port)


def fetch_livestock_diagnosis(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("diagnose_livestock.lua", host=host, port=port)


# ── Format helpers ───────────────────────────────────────────────────────────

_PRODUCTIVE_FLAGS = ("egg_layer", "grazer", "milkable", "shearable")
_ANCILLARY_FLAGS  = ("war_trainable", "hunt_trainable", "pack_animal", "mount")


def _trait_tags(a: dict) -> str:
    tags = []
    if a.get("egg_layer"):    tags.append("eggs")
    if a.get("grazer"):       tags.append("graze")
    if a.get("milkable"):     tags.append("milk")
    if a.get("shearable"):    tags.append("shear")
    if a.get("war_trainable"):  tags.append("war")
    if a.get("hunt_trainable"): tags.append("hunt")
    if a.get("pack_animal"):    tags.append("pack")
    if a.get("mount"):          tags.append("mount")
    return ("[" + "][".join(tags) + "]") if tags else ""


def _species_row(a: dict) -> str:
    sp       = a.get("species", "?")
    female   = a.get("female", 0)
    male     = a.get("male", 0)
    unk      = a.get("unknown_sex", 0)
    pregnant = a.get("pregnant", 0)
    pets     = a.get("pets", 0)
    slaughter= a.get("marked_slaughter", 0)

    sex_str  = f"{female}F {male}M"
    if unk:
        sex_str += f" {unk}?"
    preg_str = f" {pregnant}preg" if pregnant else ""
    pet_str  = f" ({pets} pet{'s' if pets != 1 else ''})" if pets else ""
    sl_str   = f" [{slaughter} slaughter]" if slaughter else ""
    trait_str = (" " + _trait_tags(a)) if _trait_tags(a) else ""

    return f"  {sp:<20} {sex_str}{preg_str}{trait_str}{pet_str}{sl_str}"


# ── Format: report ───────────────────────────────────────────────────────────

def format_livestock_report(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Load a fort, then try again.")

    animals   = data.get("tame_animals") or []
    pen_zones = data.get("pen_zones", 0)
    nest_boxes= data.get("nest_boxes", 0)

    lines = ["=== Livestock Roster ==="]

    if not animals:
        lines.append("\nNo tame animals found.")
    else:
        productive = [a for a in animals
                      if any(a.get(k) for k in _PRODUCTIVE_FLAGS)]
        prod_ids   = {a["race_id"] for a in productive}
        other      = [a for a in animals if a["race_id"] not in prod_ids]

        total = sum(
            a.get("female", 0) + a.get("male", 0) + a.get("unknown_sex", 0)
            for a in animals
        )
        lines.append(
            f"\n{total} tame animal(s) across {len(animals)} species"
        )

        # ── Productive section ───────────────────────────────────────────
        if productive:
            lines.append("\nProductive livestock:")
            for a in productive:
                lines.append(_species_row(a))

        # ── Other tame animals ───────────────────────────────────────────
        if other:
            lines.append("\nOther tame animals:")
            for a in other:
                lines.append(_species_row(a))

        # ── Inline warnings ──────────────────────────────────────────────
        warnings = []
        for a in animals:
            f, m = a.get("female", 0), a.get("male", 0)
            if (f + m) > 1 and (f == 0 or m == 0):
                missing = "males" if m == 0 else "females"
                warnings.append(
                    f"  !! {a['species']}: no {missing} — breeding impossible"
                )
        has_egg_layers = any(a.get("egg_layer") for a in animals)
        if has_egg_layers and nest_boxes == 0:
            warnings.append("  !! egg-layers present but no nest boxes built")
        has_grazers = any(a.get("grazer") for a in animals)
        if has_grazers and pen_zones == 0:
            warnings.append("  !! grazers present but no pen/pasture zone exists")

        if warnings:
            lines.append("")
            lines += warnings

    lines.append(f"\nPen zones: {pen_zones}  |  Nest boxes: {nest_boxes}")
    append_errors(lines, data)
    return "\n".join(lines)


# ── Format: diagnosis ────────────────────────────────────────────────────────

_DIAG_LABELS = {
    "has_tame_animals":   "Tame animals owned",
    "breeding_pairs":     "Breeding pairs (both sexes) for productive species",
    "pen_zone_exists":    "Pen/pasture zone for grazers",
    "nest_box_available": "Nest box for egg-layers",
    "training_level":     "Training level (control)",
    "productive_all_pets":"Productive females not all pets",
}

_DIAG_FACTS = (
    "tame_count",
    "productive_species_count",
    "species_missing_mate",
    "pen_zones",
    "nest_boxes",
    "untamed_count",
)


def format_livestock_diagnosis(data: dict) -> str:
    return format_diagnosis(
        data,
        title="=== Livestock Breeding Diagnosis ===",
        labels=_DIAG_LABELS,
        fact_keys=_DIAG_FACTS,
        none_blocker_hint=(
            "the breeding pipeline looks clear — check animal ages and "
            "whether they share a reachable area"
        ),
    )
