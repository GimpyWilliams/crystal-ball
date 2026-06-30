"""
READ-ONLY legends/lore lookups for crystal-ball: find a named artifact and its
current location, look up a deity's spheres and dedicated fort temple, and report
which deity a citizen worships (and where to honor it). Each runs one bundled,
audited Lua query (scripts/artifact_locator.lua, scripts/deity_detail.lua,
scripts/citizen_faith.lua); the selector is forwarded as DATA only -- never
executed. Nothing changes state.

These answer questions the operational tools can't: e.g. "where is the artifact
Zodost Mogshum?", "what is the deity The Noiseless Arrow?", and "which temple
should I place a given dwarf's mood artifact in?".
"""

from intel import as_map, run_intel
from reports import append_errors


def _render_candidates(data: dict) -> str:
    """Shared rendering for the 'no/many matches' candidate list, mirroring
    dwarves.format_dwarf_detail."""
    lines = [data.get("message", "Pick one:")]
    for c in (data.get("candidates") or []):
        c = as_map(c)
        prof = c.get("profession")
        suffix = f" ({prof})" if prof else ""
        lines.append(f"  #{c.get('id')}  {c.get('name', '?')}{suffix}")
    return "\n".join(lines)


# --- artifact locator ------------------------------------------------------

def fetch_artifact(selector: str, host: str = "127.0.0.1",
                   port: int = 5000) -> dict:
    return run_intel("artifact_locator.lua", [str(selector)],
                     host=host, port=port)


def _location_line(loc: dict) -> str:
    """Human-readable 'where is it' from the location object."""
    loc = as_map(loc)
    parts = []
    if loc.get("held_by"):
        parts.append(f"carried by {loc['held_by']}")
    if loc.get("inside_item"):
        parts.append(f"stored inside a {loc['inside_item']}")
    if loc.get("in_building"):
        parts.append(f"installed in a {loc['in_building']}")
    where = "; ".join(parts) if parts else "lying loose"
    if all(k in loc for k in ("x", "y", "z")):
        where += f" at ({loc['x']}, {loc['y']}, {loc['z']})"
    if loc.get("forbidden"):
        where += " [forbidden]"
    return where


def format_artifact(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."
    if data.get("need_selection"):
        return _render_candidates(data)

    a = as_map(data.get("artifact"))
    if not a:
        return "No artifact data returned."

    en = a.get("name_en")
    en_note = f' — "{en}"' if en and en != a.get("name") else ""
    lines = [f"=== {a.get('name', '?')}{en_note} (artifact #{a.get('id')}) ==="]
    if a.get("lost"):
        lines.append("This artifact's item no longer exists in the fort "
                     "(lost, destroyed, or off-site).")
        append_errors(lines, data)
        return "\n".join(lines)

    descr = " ".join(x for x in (a.get("quality"), a.get("material"),
                                 a.get("item_type")) if x)
    lines.append(f"Item: {descr or '?'}")
    if a.get("maker"):
        lines.append(f"Maker: {a['maker']}")
    lines.append(f"Location: {_location_line(a.get('location'))}")

    append_errors(lines, data)
    return "\n".join(lines)


# --- deity detail ----------------------------------------------------------

def fetch_deity(selector: str, host: str = "127.0.0.1",
                port: int = 5000) -> dict:
    return run_intel("deity_detail.lua", [str(selector)], host=host, port=port)


def format_deity(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."
    if data.get("need_selection"):
        return _render_candidates(data)

    d = as_map(data.get("deity"))
    if not d:
        return "No deity data returned."

    lines = [f"=== {d.get('name', '?')} (deity #{d.get('id')}) ==="]
    spheres = d.get("spheres") or []
    lines.append("Spheres: " + (", ".join(spheres) if spheres else "(none)"))

    temples = d.get("temples") or []
    if temples:
        lines.append("Dedicated temple(s) in this fort: " + ", ".join(temples))
    else:
        lines.append("No temple in this fort is dedicated to this deity.")

    append_errors(lines, data)
    return "\n".join(lines)


# --- citizen faith ---------------------------------------------------------

def fetch_faith(selector: str, host: str = "127.0.0.1",
                port: int = 5000) -> dict:
    return run_intel("citizen_faith.lua", [str(selector)], host=host, port=port)


def format_faith(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fortress is loaded. Load a fort, then try again."
    if data.get("need_selection"):
        return _render_candidates(data)

    d = as_map(data.get("dwarf"))
    if not d:
        return "No dwarf data returned."

    lines = [f"=== Faith of {d.get('name', '?')} (#{d.get('id')}, "
             f"{d.get('profession', '?')}) ==="]
    if d.get("note"):
        lines.append(d["note"])

    deities = d.get("deities") or []
    if not deities:
        lines.append("This dwarf worships no deity on record.")
    for dd in deities:
        dd = as_map(dd)
        spheres = dd.get("spheres") or []
        sph = f" [{', '.join(spheres)}]" if spheres else ""
        lines.append(f"\n  {dd.get('deity', '?')}{sph}  "
                     f"(worship strength {dd.get('strength', '?')})")
        temples = dd.get("temples") or []
        if temples:
            lines.append("    Temple here: " + ", ".join(temples)
                         + "  <- place this dwarf's artifact / offerings here")
        else:
            lines.append("    No temple in this fort serves this deity yet "
                         "(build/dedicate one to honor it).")

    append_errors(lines, data)
    return "\n".join(lines)
