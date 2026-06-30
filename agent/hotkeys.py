"""
F-key map bookmark (hotkey) intel for crystal-ball (READ-ONLY).

`fetch_hotkeys_intel` / `format_hotkeys_report` surface all 16 F-key map
bookmarks from df.global.plotinfo.main.hotkeys, showing the label, name,
coordinates, and whether each slot is active (cmd == 0).

The reversible hotkey WRITE that pairs with this view lives in mutations.py
(_set_hotkey / set_hotkey MCP tool).
"""

from intel import run_intel, as_map
from reports import append_errors


def fetch_hotkeys_intel(host: str = "127.0.0.1", port: int = 5000) -> dict:
    return run_intel("hotkeys_intel.lua", host=host, port=port)


def format_hotkeys_report(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    hotkeys = data.get("hotkeys") or []
    active = [h for h in hotkeys if as_map(h).get("active")]
    lines = [f"=== Map Hotkeys (F1-F16) — {len(active)} active ==="]

    for h in hotkeys:
        h = as_map(h)
        key = h.get("key", "?")
        if h.get("active"):
            lines.append(f"  {key:<4}  {h.get('name', ''):<28}  "
                         f"({h.get('x')}, {h.get('y')}, {h.get('z')})")
        else:
            lines.append(f"  {key:<4}  (unset)")

    append_errors(lines, data)
    return "\n".join(lines)
