"""
Minecart logistics status for crystal-ball (READ-ONLY).

`fetch_minecart_status` / `format_minecart_status` report what the minecart
project has built so far: minecart items and whether each rides a route, the
hauling routes with their stops and linked stockpiles, track stops and rollers,
outstanding minecart orders, 1x1 (quantum) stockpiles, and -- given a z level --
how many dig designations are still waiting on that level (the strip-mine grid).

Minecarts are ordered with queue_work_order(job='MakeTool', item='minecart').
"""

from intel import run_intel, as_map
from reports import append_errors

STRIP_MINE_Z = 20  # the pattern 1 grid level; pass z=-1 to skip the dig count


def fetch_minecart_status(z: int = STRIP_MINE_Z, host: str = "127.0.0.1",
                          port: int = 5000) -> dict:
    args = [str(z)] if z is not None and z >= 0 else []
    return run_intel("minecart_intel.lua", args, host=host, port=port)


def format_minecart_status(data: dict) -> str:
    if not data.get("fort_loaded"):
        return ("No fortress is loaded. Open or embark a fort in Dwarf "
                "Fortress, then run this again.")

    carts = data.get("carts") or []
    routes = data.get("routes") or []
    stops = data.get("trackstops") or []
    orders = data.get("orders") or []
    on_route = sum(1 for c in carts if as_map(c).get("route") not in (None, -1))
    lines = ["=== Minecarts ===",
             f"Carts: {len(carts)} ({on_route} on a route, "
             f"{len(carts) - on_route} free)   Routes: {len(routes)}   "
             f"Track stops: {len(stops)}   Rollers: {data.get('rollers', 0)}"]

    if orders:
        left = sum(as_map(o).get("left", 0) for o in orders)
        lines.append(f"Minecart orders: {len(orders)} open, {left} carts still "
                     "to make")
    for c in carts:
        c = as_map(c)
        where = f"({c.get('x')},{c.get('y')},{c.get('z')})"
        route = c.get("route")
        tag = f"route #{route}" if route not in (None, -1) else "free"
        lines.append(f"  cart #{c.get('id')} {c.get('mat')} at {where}, {tag}"
                     + (", FORBIDDEN" if c.get("forbidden") else ""))

    if routes:
        lines.append("\nRoutes:")
    for r in routes:
        r = as_map(r)
        rs = r.get("stops") or []
        lines.append(f"  #{r.get('id')} {r.get('name') or '(unnamed)'}: "
                     f"{len(rs)} stop(s), {r.get('vehicles', 0)} cart(s)"
                     + ("" if r.get("vehicles") else
                        "  <- run `assign-minecarts all` in DFHack"))
        for s in rs:
            s = as_map(s)
            piles = s.get("piles") or []
            lines.append(f"      stop {s.get('name') or s.get('id')} at "
                         f"({s.get('x')},{s.get('y')},{s.get('z')}): "
                         f"{s.get('conditions', 0)} condition(s), linked piles "
                         + (", ".join(f"#{p}" for p in piles) or "none"))

    if stops:
        lines.append("\nTrack stops:")
    for s in stops:
        s = as_map(s)
        dump = as_map(s.get("dump"))
        lines.append(f"  ({s.get('x')},{s.get('y')},{s.get('z')}) friction "
                     f"{s.get('friction', '?')}"
                     + (f", dumps ({dump.get('dx')},{dump.get('dy')})" if dump
                        else ""))

    quantum = data.get("quantum") or []
    if quantum:
        lines.append("\n1x1 stockpiles (quantum targets):")
        for q in quantum:
            q = as_map(q)
            lines.append(f"  #{q.get('number')} {q.get('name') or '(unnamed)'} "
                         f"at ({q.get('x')},{q.get('y')},{q.get('z')})")

    dig = as_map(data.get("dig"))
    if dig:
        by = as_map(dig.get("by_type"))
        detail = ", ".join(f"{k} {v}" for k, v in sorted(by.items()))
        lines.append(f"\nDig designations left on z{dig.get('z')}: "
                     f"{dig.get('total', 0)}" + (f" ({detail})" if detail else ""))

    append_errors(lines, data)
    return "\n".join(lines)
