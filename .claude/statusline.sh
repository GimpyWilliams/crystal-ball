#!/usr/bin/env bash
# Dwarf Fortress-flavored dynamic status line for df_hack project

input=$(cat)

eval "$(printf '%s' "$input" | python "$HOME/.claude/statusline_parse.py")"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
agent_dir="$script_dir/../agent"
df_cache="$agent_dir/data/statusline_cache.json"
df_lock="$agent_dir/data/statusline_refresh.lock"
df_cache_ttl=180   # seconds -- re-fetch from DFHack once the cache is this stale
df_lock_ttl=30     # seconds -- don't stack a second background refresh this soon

parts=()

if [ -n "$cwd" ]; then
    short_dir=$(basename "$cwd")
    parts+=("⛰️ ${short_dir}")
fi

if [ -n "$model" ]; then
    parts+=("⛏️ ${model}")
fi

if [ -n "$remaining" ]; then
    remaining_int=$(printf "%.0f" "$remaining")
    if [ "$remaining_int" -le 10 ]; then
        parts+=("💀 Legends: ${remaining_int}% remain")
    elif [ "$remaining_int" -le 30 ]; then
        parts+=("💎 Caverns: ${remaining_int}% remain")
    else
        parts+=("🌲 Vault: ${remaining_int}% remain")
    fi
fi

if [ -n "$five_hour" ]; then
    five_int=$(printf "%.0f" "$five_hour")
    parts+=("🪨 5h: ${five_int}%")
fi

if [ -n "$repo" ]; then
    parts+=("⛏️ ${repo}")
fi

if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    upstream=$(git -C "$cwd" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
    if [ -n "$upstream" ]; then
        counts=$(git -C "$cwd" rev-list --left-right --count "HEAD...${upstream}" 2>/dev/null)
        read -r ahead behind <<< "$counts"
        if [ "${ahead:-0}" != "0" ] || [ "${behind:-0}" != "0" ]; then
            git_bits=""
            [ "${ahead:-0}" != "0" ] && git_bits="${git_bits}↑${ahead}"
            [ "${behind:-0}" != "0" ] && git_bits="${git_bits}↓${behind}"
            parts+=("⛏️ ${git_bits}")
        fi
    fi
fi

if [ -n "$vim_mode" ]; then
    case "$vim_mode" in
        INSERT) parts+=("⛏️ MINING") ;;
        NORMAL) parts+=("⛰️ SURVEYING") ;;
        VISUAL) parts+=("💎 APPRAISING") ;;
        "VISUAL LINE") parts+=("💎 APPRAISING LINE") ;;
        *) parts+=("${vim_mode}") ;;
    esac
fi

# Fort snapshot (dwarf moods / key stock levels+deltas / in-game clock): read
# from the on-disk cache only (instant); DFHack is queried by a background
# refresh so the render never blocks on it. TTLs keep this to one refresh
# process at a time, roughly every df_cache_ttl seconds.
now=$(date +%s)

cache_age=999999
if [ -f "$df_cache" ]; then
    cache_mtime=$(stat -c %Y "$df_cache" 2>/dev/null || stat -f %m "$df_cache" 2>/dev/null)
    [ -n "$cache_mtime" ] && cache_age=$((now - cache_mtime))
fi

lock_age=999999
if [ -f "$df_lock" ]; then
    lock_mtime=$(stat -c %Y "$df_lock" 2>/dev/null || stat -f %m "$df_lock" 2>/dev/null)
    [ -n "$lock_mtime" ] && lock_age=$((now - lock_mtime))
fi

if [ "$cache_age" -gt "$df_cache_ttl" ] && [ "$lock_age" -gt "$df_lock_ttl" ]; then
    touch "$df_lock" 2>/dev/null
    (
        "$agent_dir/.venv/Scripts/python.exe" "$agent_dir/statusline.py" refresh >/dev/null 2>&1
        rm -f "$df_lock"
    ) &
    disown 2>/dev/null || true
fi

if [ -f "$df_cache" ]; then
    df_line=$("$agent_dir/.venv/Scripts/python.exe" "$agent_dir/statusline.py" 2>/dev/null)
    [ -n "$df_line" ] && parts+=("$df_line")
fi

# Fallback: if nothing rendered at all, show the MCP hint
if [ ${#parts[@]} -eq 0 ]; then
    printf '%s' '🔮 crystal-ball ⛰️🌲⛰️ · 📦 stock · 🛢️ barrels · 🏭 shops · 🧑‍🤝‍🧑 dwarves · 🍺 brewing · 🔍 diagnose · 🪨 DF must be running ⛏️'
    exit 0
fi

printf '%s' "$(IFS='  |  '; echo "${parts[*]}")"
