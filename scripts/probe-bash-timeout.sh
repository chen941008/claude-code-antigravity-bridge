#!/usr/bin/env bash
# Probes whether Claude Code's Bash tool kills the whole process tree when it times out.
# No agy, no quota. Usage:
#   run    - (inside Claude Code, with a short Bash timeout) start a parent + child that log heartbeats
#   check  - (any terminal, ~10s later) report whether they survived the timeout
#   clean  - kill leftovers
set -uo pipefail
STATE="${TMPDIR:-/tmp}/cc-timeout-probe"

case "${1:-}" in
run)
    rm -rf "$STATE" && mkdir -p "$STATE"
    echo $$ > "$STATE/parent.pid"
    # The child mimics agy's own subprocesses (language servers, tool runs, ...).
    ( while :; do date +%s >> "$STATE/child.beat"; sleep 1; done ) &
    echo $! > "$STATE/child.pid"
    while :; do date +%s >> "$STATE/parent.beat"; sleep 1; done
    ;;
check)
    now=$(date +%s)
    for who in parent child; do
        pid=$(cat "$STATE/$who.pid" 2>/dev/null || echo "")
        last=$(tail -n1 "$STATE/$who.beat" 2>/dev/null || echo 0)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then alive=ALIVE; else alive=dead; fi
        echo "$who pid=${pid:-?} $alive, last heartbeat $((now - last))s ago"
    done
    echo "Both dead = Claude Code kills the tree. ALIVE = orphan risk is real (run 'clean')."
    ;;
clean)
    for who in child parent; do
        pid=$(cat "$STATE/$who.pid" 2>/dev/null) && kill "$pid" 2>/dev/null
    done
    rm -rf "$STATE"
    echo "cleaned"
    ;;
*)
    echo "usage: $0 run|check|clean"; exit 1
    ;;
esac
