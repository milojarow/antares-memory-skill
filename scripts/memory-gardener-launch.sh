#!/usr/bin/env bash
# SessionEnd hook — fire-and-forget launcher for the "gardener" lobo.
# Three guards so it never bites: (1) gate — runs at most once per ~24h;
# (2) lockfile — one gardener at a time; (3) background+disown — NEVER blocks
# session close. The gardener itself (agents-sdk/gardener.mjs) is isolated and
# non-destructive (annotate + report only).
#
# Scaling fix: a base with 150+ memories times out a lobo that Reads every body
# (observed: rc=124 at 300s). So bash builds a DIGEST (full-path: description) of
# every memory and passes it INLINE. The gardener spots suspicious PAIRS from the
# digest, then Reads only those few to confirm before annotating — it never sweeps
# all N. IO triage in bash, judgment in the LLM.
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

# Build a digest line per memory: "- <full-path>: <frontmatter description>".
# Full path (not just filename) so the gardener can Read/annotate the right file.
build_digest() {
    local dir="$1" f b d
    shopt -s nullglob
    for f in "$dir"/*.md; do
        b=$(basename "$f")
        [[ "$b" == "MEMORY.md" ]] && continue
        d=$(grep -m1 '^description:' "$f" 2>/dev/null \
            | sed -E 's/^description:[[:space:]]*//; s/^"//; s/"$//')
        [[ -z "$d" ]] && d="(no description)"
        printf -- '- %s: %s\n' "$f" "$d"
    done
    shopt -u nullglob
}

digest="$(build_digest "$home_dir")"
if [[ "$current_dir" != "$home_dir" ]]; then
    cur="$(build_digest "$current_dir")"
    [[ -n "$cur" ]] && digest="$digest
$cur"
fi
n_mem=$(printf '%s' "$digest" | grep -c '^- ' || true)

task="Today is $today.

== ALL MEMORIES ($n_mem total — full-path: description) ==
$digest

Work from the digest. Spot HIGH-CONFIDENCE near-duplicates, contradictions, and
time-obsolescence by comparing the descriptions. Read ONLY the few files in a
suspicious pair to confirm before acting — NEVER read all $n_mem. Annotate each
confirmed-stale file with a single line and print the GARDEN SUMMARY per your
policy. Do NOT touch MEMORY.md."

# Guard 3 — fire-and-forget: run detached so session close returns immediately.
log "LAUNCH gardener (background) cwd=$cwd memories=$n_mem"
(
    trap 'rm -f "$LOCK"' EXIT
    export CLAUDE_HEADLESS=1  # defense-in-depth vs hook recursion
    out=$(printf '%s' "$task" | timeout "${ANTARES_GARDENER_TIMEOUT:-420}" \
        node "$SCRIPT_DIR/../agents-sdk/gardener.mjs" 2>>"$LOG")
    rc=$?
    echo "$now" > "$STAMP"  # stamp after attempting (avoid retry-storm on errors)
    result=$(printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null | head -c 1500)
    log "DONE rc=$rc result=$result"
) >/dev/null 2>&1 &
disown

exit 0
