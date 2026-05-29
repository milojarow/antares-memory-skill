#!/usr/bin/env bash
# SessionEnd hook — fire-and-forget launcher for the "index-curator" lobo.
# Guards: gate (~7d — the index changes slowly), lock, background+disown.
#
# Scaling fix: a base with 150+ memories times out a lobo that Reads bodies.
# Deciding the INDEX needs only each memory's frontmatter `description`, not its
# body. So bash builds a DIGEST (filename + description) and passes it INLINE,
# with MEMORY.md, in the task prompt. The lobo judges from the prompt in a few
# turns — no base sweep. IO in bash, judgment in the LLM (same split as extractor).
#
# Failsafe: ANY error → exit 0.

trap 'exit 0' ERR
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

LOG="$ANTARES_STATE/logs/memory-curator.log"
LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/antares-memory-curator.lock"
STAMP="$ANTARES_STATE/curator-last-run"

ts() { date -Iseconds; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >>"$LOG"; }

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$cwd" ]] && cwd="$PWD"

now=$(date +%s)

# Gate: at most once per ~7 days.
if [[ -f "$STAMP" ]]; then
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    if (( now - last < 604800 )); then
        log "SKIP gate: last run $(( now - last ))s ago (<7d)"
        exit 0
    fi
fi

# Lock: one curator at a time.
if ! ( set -o noclobber; echo $$ > "$LOCK" ) 2>/dev/null; then
    log "SKIP lock held (pid=$(cat "$LOCK" 2>/dev/null || echo ?))"
    exit 0
fi

home_dir="$(antares_home_memory_dir)"
mem_index="$home_dir/MEMORY.md"
today=$(date +%Y-%m-%d)

# Build the digest: filename + frontmatter description of every memory (NOT bodies).
digest=""
shopt -s nullglob
for f in "$home_dir"/*.md; do
    base=$(basename "$f")
    [[ "$base" == "MEMORY.md" ]] && continue
    desc=$(grep -m1 '^description:' "$f" 2>/dev/null \
        | sed -E 's/^description:[[:space:]]*//; s/^"//; s/"$//')
    [[ -z "$desc" ]] && desc="(no description)"
    digest+="- ${base}: ${desc}"$'\n'
done
shopt -u nullglob

n_mem=$(printf '%s' "$digest" | grep -c '^- ' || true)
index_body=$(cat "$mem_index" 2>/dev/null || echo "(MEMORY.md absent)")

task="Today is $today. Curate the always-on index.

== CURRENT INDEX (MEMORY.md — do NOT edit) ==
$index_body

== ALL MEMORIES ($n_mem total — filename: description) ==
$digest

Judge from the digest above. Only Read a specific file under $home_dir if you must confirm a single candidate — never sweep the base. Write your promotions/demotions to $home_dir/.index-suggestions.md per your policy. NEVER edit MEMORY.md."

log "LAUNCH index-curator (background) cwd=$cwd memories=$n_mem"
(
    trap 'rm -f "$LOCK"' EXIT
    export CLAUDE_HEADLESS=1
    out=$(printf '%s' "$task" | timeout "${ANTARES_CURATOR_TIMEOUT:-300}" \
        node "$SCRIPT_DIR/../agents-sdk/index-curator.mjs" 2>>"$LOG")
    rc=$?
    echo "$now" > "$STAMP"
    result=$(printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null | head -c 1000)
    log "DONE rc=$rc result=$result"
) >/dev/null 2>&1 &
disown

exit 0
