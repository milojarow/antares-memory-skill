#!/usr/bin/env bash
# SessionEnd hook — fire-and-forget launcher for the "gardener" lobo.
# Three guards so it never bites: (1) gate — runs at most once per ~24h;
# (2) lockfile — one gardener at a time; (3) background+disown — NEVER blocks
# session close. The gardener itself (agents-sdk/gardener.mjs) is isolated and
# non-destructive (annotate + report only).
#
# Failsafe: ANY error → exit 0. Never block session close.

trap 'exit 0' ERR
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

LOG="$ANTARES_STATE/logs/memory-gardener.log"
LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/antares-memory-gardener.lock"
STAMP="$ANTARES_STATE/gardener-last-run"

ts() { date -Iseconds; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >>"$LOG"; }

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$cwd" ]] && cwd="$PWD"

now=$(date +%s)

# Guard 1 — gate: at most once per ~24h, regardless of how many sessions close.
if [[ -f "$STAMP" ]]; then
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    if (( now - last < 86400 )); then
        log "SKIP gate: last run $(( now - last ))s ago (<24h)"
        exit 0
    fi
fi

# Guard 2 — lock: one gardener at a time (covers near-simultaneous SessionEnds).
if ! ( set -o noclobber; echo $$ > "$LOCK" ) 2>/dev/null; then
    log "SKIP lock held (pid=$(cat "$LOCK" 2>/dev/null || echo ?))"
    exit 0
fi

home_dir="$(antares_home_memory_dir)"
current_dir="$(antares_memory_dir_for "$cwd")"
today=$(date +%Y-%m-%d)

if [[ "$current_dir" == "$home_dir" ]]; then
    dirs_block="Garden this memory dir:
  $home_dir"
else
    dirs_block="Garden these memory dirs:
  HOME:    $home_dir
  CURRENT: $current_dir"
fi

task="Today is $today.

$dirs_block

Cross-check the existing memory files per your policy: flag near-duplicates, contradictions, and time-obsolescence. Annotate (one line per stale file) + report. Do NOT delete or destructively merge. Print the GARDEN SUMMARY and exit."

# Guard 3 — fire-and-forget: run detached so session close returns immediately.
log "LAUNCH gardener (background) cwd=$cwd"
(
    trap 'rm -f "$LOCK"' EXIT
    export CLAUDE_HEADLESS=1  # defense-in-depth vs hook recursion
    out=$(printf '%s' "$task" | timeout "${ANTARES_GARDENER_TIMEOUT:-300}" \
        node "$SCRIPT_DIR/../agents-sdk/gardener.mjs" 2>>"$LOG")
    rc=$?
    echo "$now" > "$STAMP"  # stamp after attempting (avoid retry-storm on errors)
    result=$(printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null | head -c 1500)
    log "DONE rc=$rc result=$result"
) >/dev/null 2>&1 &
disown

exit 0
