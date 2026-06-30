from __future__ import annotations

from intel import run_intel


def fetch_announcements(limit: int = 50) -> dict:
    return run_intel("announcements.lua", [str(limit)])


def format_announcements(data: dict) -> str:
    if not data.get("fort_loaded"):
        return "No fort loaded."
    lines = ["=== Recent Announcements ===", ""]
    anns = data.get("announcements", [])
    if not anns:
        lines.append("  (no announcements)")
    else:
        for a in anns:
            year = a.get("year", "?")
            t    = a.get("time", "?")
            kind = a.get("type", "UNKNOWN")
            pos  = a.get("pos")
            loc  = f" @ ({pos['x']},{pos['y']},{pos['z']})" if pos else ""
            text = a.get("text", "")
            lines.append(
                f"[{year}/{t}] {kind}{loc}: {text}" if text else
                f"[{year}/{t}] {kind}{loc}"
            )
    lines.append("")
    lines.append(f"Showing {data.get('shown', 0)} of {data.get('total', 0)} total reports.")
    if data.get("errors"):
        lines.append("Errors: " + "; ".join(data["errors"]))
    return "\n".join(lines)
