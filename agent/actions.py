"""
Shared helper for running vetted WRITE ("act") DFHack Lua scripts.

This is the deliberate sibling of intel.run_intel(): the read side runs audited
queries from scripts/; this runs audited *mutation* scripts from scripts/actions/.
The exact same safety invariant holds -- the only Lua ever executed is the fixed
mutation prelude (scripts/actions/_prelude.lua) prepended to one of the fixed,
audited files in scripts/actions/. Caller input is forwarded as the Lua `...`
varargs and is DATA only (a JSON spec of orders to create: ids, amounts,
material classes, job/reaction names), never code to execute.

Mutation scripts are required to:
  * validate every enum lookup (job_type / reaction / material) BEFORE writing,
    so a bad name returns an error instead of corrupting a struct, and
  * wrap each write in pcall and report {"ok":bool,"created":[...],"errors":[...]}
    so a partial failure surfaces rather than silently half-applying.

Nothing here runs unless a feature is invoked in mode='apply' with confirm=True;
see mutations.py for the gate.
"""

import json
from pathlib import Path

from dfhack_rpc.client import DFHackClient, DFHackError

_ACTIONS = Path(__file__).resolve().parent / "scripts" / "actions"

# Read once at import. Prepended to every mutation script so the shared write
# helpers are in scope -- mirrors intel.py's handling of the read prelude.
_PRELUDE = (_ACTIONS / "_prelude.lua").read_text(encoding="utf-8")


def run_action(script_name: str, args: list[str] | None = None, *,
               host: str = "127.0.0.1", port: int = 5000) -> dict:
    """Run a bundled mutation Lua script by file name and return parsed JSON.

    `script_name` must name a file in scripts/actions/. It is never
    caller-supplied Lua -- only the fixed, audited files in that directory run.
    `args` are forwarded as Lua `...` varargs (a JSON spec string); they are
    DATA, not code, so the fixed-script safety invariant holds.
    """
    path = _ACTIONS / script_name
    lua = _PRELUDE + "\n" + path.read_text(encoding="utf-8")
    with DFHackClient(host=host, port=port) as client:
        raw = client.run_command("lua", [lua, *(args or [])])
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        raise DFHackError(
            f"could not parse {script_name} output as JSON: {e}\n"
            f"--- output ---\n{raw}"
        ) from e
