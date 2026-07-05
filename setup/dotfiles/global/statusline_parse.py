#!/usr/bin/env python
"""Parse Claude Code status-line JSON (from stdin) into shell variable
assignments (on stdout), for scripts on machines without jq installed.
Usage: eval "$(python "$HOME/.claude/statusline_parse.py")"
"""
import json
import shlex
import sys


def get(d, *keys, default=""):
    cur = d
    for k in keys:
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            return default
    return cur if cur is not None else default


def main():
    data = json.load(sys.stdin)

    cwd = get(data, "workspace", "current_dir") or get(data, "cwd")
    model = get(data, "model", "display_name")
    remaining = get(data, "context_window", "remaining_percentage")
    five_hour = get(data, "rate_limits", "five_hour", "used_percentage")
    repo = get(data, "workspace", "repo")
    repo_str = f"{repo['owner']}/{repo['name']}" if isinstance(repo, dict) and repo else ""
    pr = get(data, "pr", "number")
    pr_state = get(data, "pr", "review_state", default="open")
    vim_mode = get(data, "vim", "mode")

    fields = {
        "cwd": cwd,
        "model": model,
        "remaining": remaining,
        "five_hour": five_hour,
        "repo": repo_str,
        "pr": pr,
        "pr_state": pr_state,
        "vim_mode": vim_mode,
    }
    for name, val in fields.items():
        print(f"{name}={shlex.quote(str(val))}")


if __name__ == "__main__":
    main()
