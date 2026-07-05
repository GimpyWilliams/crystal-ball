#!/usr/bin/env bash
# SessionStart hook for the df_hack project. Its stdout is added to Claude's
# context, so it instructs Claude to open the session with a usage reminder
# for the read-only Dwarf Fortress intel MCP server.
cat >/dev/null 2>&1
cat <<'EOF'
[df_hack session note] Begin this session by greeting the user with the
following Dwarf Fortress intel MCP usage reminder (show it once, near the top
of your first reply, keeping the emojis):

  🔮 The crystal-ball MCP server is connected and is READ-ONLY. 🔒
  It reads a live fort over DFHack RPC to troubleshoot any industry — not just beer.

  What you can ask for in plain chat:
  • 📦 Stock & items — "What items do I have?" available vs total, any pipeline (stock_report)
  • 🧲 Acquirable — "What stock is stuck/uncollected/loose/at the depot?" (acquirable_items)
  • 🛢️ Storage — "Are my barrels/bins full?" (container_report)
  • 🏭 Workshops & orders — "Which workshops are idle? Are my orders active?" (shops_and_orders_report)
  • 🧑‍🤝‍🧑 Dwarves — "Show me the roster" / "Diagnose <name>" / "Who can brew?" (dwarf_roster, dwarf_detail, labor_coverage)
  • 🍺 Brewing — "What's my beer production status?" (brewing_report)
  • 🔍 Root cause — "Why is nobody making beer?" (diagnose_brewing) — chains the checks for you

  Every tool has a *_data twin that returns the same as JSON. 📊
  💻 Terminal: cd agent && .venv/Scripts/python.exe cli.py <brewing|stock|containers|shops|diagnose|roster|dwarf NAME|labor NAME>
  🎮 Requires Dwarf Fortress running with a fort loaded (DFHack on 127.0.0.1:5000).
  ✋ Nothing here changes the fort; write actions are only built when asked by name.
EOF
