#!/usr/bin/env bash
# Dwarf Fortress-flavored Claude Code status line

input=$(cat)

eval "$(printf '%s' "$input" | python "$HOME/.claude/statusline_parse.py")"

parts=()

if [ -n "$cwd" ]; then
    short_dir=$(basename "$cwd")
    parts+=("⛰ ${short_dir}")
fi

if [ -n "$model" ]; then
    parts+=("⛏ ${model}")
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
    parts+=("⛏ ${repo}")
fi

if [ -n "$pr" ]; then
    parts+=("PR #${pr} [${pr_state}]")
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
            parts+=("⛏ ${git_bits}")
        fi
    fi
fi

if [ -n "$vim_mode" ]; then
    case "$vim_mode" in
        INSERT) parts+=("⛏ MINING") ;;
        NORMAL) parts+=("⛰ SURVEYING") ;;
        VISUAL) parts+=("💎 APPRAISING") ;;
        "VISUAL LINE") parts+=("💎 APPRAISING LINE") ;;
        *) parts+=("${vim_mode}") ;;
    esac
fi

printf '%s' "$(IFS='  |  '; echo "${parts[*]}")"
