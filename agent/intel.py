"""
Shared helper for running vetted READ-ONLY DFHack Lua queries.

Every "intel" feature in this project follows the same recipe: a bundled,
audited Lua script under scripts/ is sent through DFHack's RunCommand RPC and
its JSON output is parsed. No command string is ever taken from a caller -- the
only thing ever executed is the fixed prelude (scripts/_prelude.lua) prepended
to one of the fixed script files in scripts/. Both are bundled, audited files.

The prelude defines the canonical shared helpers (matname/matdesc/is_available/
section/add/labor_check/finish and the `report`/`world` globals); scripts rely on
those globals rather than redefining them per file.
"""

import contextlib
import contextvars
import json
from pathlib import Path

from dfhack_rpc.client import DFHackClient, DFHackError

_SCRIPTS = Path(__file__).resolve().parent / "scripts"

# Read once at import. Prepended to every query so the shared helpers are in
# scope. A fix to a helper here applies to every script uniformly.
_PRELUDE = (_SCRIPTS / "_prelude.lua").read_text(encoding="utf-8")

# An optional connection that nested run_intel() calls reuse instead of each
# opening its own socket. Set only inside a shared_connection() block; default
# None means "open a fresh, short-lived connection per call" (the original
# behaviour). A ContextVar (not a plain global) so concurrent callers can't
# clobber each other's client.
_active_client: "contextvars.ContextVar[DFHackClient | None]" = \
    contextvars.ContextVar("active_client", default=None)


@contextlib.contextmanager
def shared_connection(host: str = "127.0.0.1", port: int = 5000):
    """Open ONE DFHack connection and have every run_intel() call inside the
    block reuse it, instead of each fetch opening (and tearing down) its own
    socket + handshake. Amortizes connection setup across a batch of reads --
    e.g. a multi-fetch tool or a fort briefing. The connection is loopback-only
    and read-driven exactly as before; only the socket is shared.

    Nesting is a no-op: an inner block reuses the outer block's client.
    """
    if _active_client.get() is not None:
        yield _active_client.get()  # already inside a shared block; reuse it
        return
    with DFHackClient(host=host, port=port) as client:
        token = _active_client.set(client)
        try:
            yield client
        finally:
            _active_client.reset(token)


def run_intel(script_name: str, args: list[str] | None = None, *,
              host: str = "127.0.0.1", port: int = 5000) -> dict:
    """Run a bundled read-only Lua query by file name and return parsed JSON.

    `script_name` must name a file in scripts/. It is never caller-supplied
    Lua -- only the fixed, audited files in that directory are ever run.

    `args` are forwarded to the script as Lua `...` varargs. They are DATA,
    not code: the scripts use them only as lookup/filter values (a dwarf id or
    name, a labor name), never as something to execute. So the fixed-script
    safety invariant holds -- the executed code is still only the audited file.

    If called inside a shared_connection() block the open client is reused
    (host/port args are then ignored -- the block already chose them); otherwise
    a fresh short-lived connection is opened for this one call.
    """
    path = _SCRIPTS / script_name
    lua = _PRELUDE + "\n" + path.read_text(encoding="utf-8")
    client = _active_client.get()
    if client is not None:
        raw = client.run_command("lua", [lua, *(args or [])])
    else:
        with DFHackClient(host=host, port=port) as fresh:
            raw = fresh.run_command("lua", [lua, *(args or [])])
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        raise DFHackError(
            f"could not parse {script_name} output as JSON: {e}\n"
            f"--- output ---\n{raw}"
        ) from e


def as_map(value) -> dict:
    """DFHack's JSON encodes an empty Lua table as [], not {}; normalize."""
    return value if isinstance(value, dict) else {}
