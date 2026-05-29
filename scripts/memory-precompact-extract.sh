#!/usr/bin/env bash
# PreCompact hook — spawn headless `claude -p` to extract durable memories
# from the transcript before context compression discards conversation history.
#
# Failsafe: ANY error → exit 0 with log. Never block compaction.

trap 'exit 0' ERR
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

LOG="$ANTARES_STATE/logs/memory-precompact.log"
PROMPT_FILE="$SCRIPT_DIR/memory-precompact-prompt.txt"
LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/antares-memory-precompact.lock"

input=$(cat)
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
trigger=$(printf '%s' "$input" | jq -r '.trigger // "unknown"' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$cwd" ]] && cwd="$PWD"

ts() { date -Iseconds; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >>"$LOG"; }

log "INVOKED session=$session_id trigger=$trigger cwd=$cwd transcript=$transcript_path"

if ! antares_venv_ready; then
    log "SKIP venv not ready ($ANTARES_VENV_PY)"
    exit 0
fi

# Resolve the two memory dirs the extractor may write to.
home_dir="$(antares_home_memory_dir)"
current_dir="$(antares_memory_dir_for "$cwd")"

log "HOME_DIR=$home_dir CURRENT_DIR=$current_dir"

if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
    log "SKIP no transcript_path or file missing"
    exit 0
fi

if ! ( set -o noclobber; echo $$ > "$LOCK" ) 2>/dev/null; then
    log "SKIP another extractor running (pid=$(cat "$LOCK" 2>/dev/null || echo ?))"
    exit 0
fi
trap 'rm -f "$LOCK"' EXIT

# Pre-process: extract text-only transcript so the sub-claude doesn't burn
# turns iterating through 2-5MB of raw tool calls / tool results.
PREPARED="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/antares-memory-precompact-prepared.md"
{
    echo "# Conversation transcript (text content only, last ~100KB)"
    echo ""
    jq -r '
      select(.type == "user" or .type == "assistant") |
      .message.content[]? |
      select(.type == "text") |
      "## [" + (.type // "unknown") + "]\n\n" + .text + "\n"
    ' "$transcript_path" 2>>"$LOG" | tail -c 100000
} > "$PREPARED"
prepared_size=$(stat -c %s "$PREPARED" 2>/dev/null || echo 0)
log "PREPARED size=${prepared_size}B path=$PREPARED"

# Build the scope block: tell the sub-claude where home/current live.
if [[ "$current_dir" == "$home_dir" ]]; then
    scope_block="The parent session's CWD is:
  $cwd

This is \$HOME — there is only one memory dir (the 'home' slug, which is the global by convention):
  $home_dir

Write all extracted memories there."
else
    scope_block="The parent session's CWD is:
  $cwd

Two memory dirs are available:
  HOME (the 'global' by convention):  $home_dir
  CURRENT (this cwd's slug dir):      $current_dir

Decide per memory:
- Cross-cutting lessons (tool quirks, OS gotchas, behavioral feedback applicable to ANY cwd, deep app knowledge) → HOME.
- Context that only matters when working in this cwd (architecture decisions for this codebase, ongoing TODOs, project-specific gotchas) → CURRENT.

When in doubt → HOME. A useful HOME memory occasionally appearing while you're in another cwd is harmless. A CURRENT memory that should have been HOME is invisible everywhere else."
fi

sub_prompt="Compaction is about to happen for session $session_id (trigger=$trigger).

Read the pre-extracted text-only transcript at:
  $PREPARED

It contains the user and assistant messages from the recent session (capped at last ~100KB), with tool calls and tool results stripped. Extract durable memories worth saving.

$scope_block

Follow the policy in your appended system prompt strictly. Dedup before writing (grep + ls in BOTH dirs if applicable). When done, print the EXTRACTION SUMMARY block and exit. Do not wait for input."

start=$(date +%s)
export CLAUDE_HEADLESS=1

log "BEFORE_CLAUDE"
trap - ERR
set +e
# extractor lobo — Agent SDK, ISOLATED (settingSources []). Reads the sub-prompt
# on stdin; prints a CLI-compatible JSON envelope. Replaces the contaminated
# `claude -p` (which loaded CLAUDE.md + persona). CLAUDE_HEADLESS stays set as
# defense-in-depth against the search-hook re-triggering, in case settingSources
# does not fully suppress plugin hooks.
output=$(timeout --kill-after=5 "$ANTARES_PRECOMPACT_TIMEOUT" \
    node "$SCRIPT_DIR/../agents-sdk/extractor.mjs" <<<"$sub_prompt" 2>>"$LOG")
rc=$?
log "AFTER_CLAUDE rc=$rc output_len=${#output}"
trap 'exit 0' ERR
set -e
elapsed=$(( $(date +%s) - start ))

if (( rc == 124 || rc == 137 )); then
    log "TIMEOUT after ${elapsed}s rc=$rc"
elif (( rc != 0 )); then
    subtype=$(printf '%s' "$output" | jq -r '.subtype // empty' 2>/dev/null || true)
    cost=$(printf '%s' "$output" | jq -r '.total_cost_usd // "?"' 2>/dev/null || echo "?")
    if [[ "$subtype" == "error_max_budget_usd" ]]; then
        log "BUDGET_EXCEEDED rc=$rc elapsed=${elapsed}s spent=\$$cost — files written before cap may be present"
    else
        log "ERROR rc=$rc elapsed=${elapsed}s subtype=$subtype cost=\$$cost"
        printf '%s' "$output" | head -c 800 >>"$LOG"
        printf '\n' >>"$LOG"
    fi
else
    cost=$(printf '%s' "$output" | jq -r '.total_cost_usd // .usage.cost_usd // "?"' 2>/dev/null || echo "?")
    turns=$(printf '%s' "$output" | jq -r '.num_turns // "?"' 2>/dev/null || echo "?")
    log "OK elapsed=${elapsed}s cost=$cost turns=$turns"
    result=$(printf '%s' "$output" | jq -r '.result // empty' 2>/dev/null | head -c 2000)
    [[ -n "$result" ]] && log "RESULT: $result"
fi

# Reindex home + current (if different) so the next session sees the new memories.
log "REINDEX home start"
if timeout 60 "$ANTARES_VENV_PY" "$SCRIPT_DIR/memory-index.py" --scope home >>"$LOG" 2>&1; then
    log "REINDEX home done"
else
    log "REINDEX home failed rc=$?"
fi

if [[ "$current_dir" != "$home_dir" ]]; then
    log "REINDEX current start (cwd=$cwd)"
    if timeout 60 "$ANTARES_VENV_PY" "$SCRIPT_DIR/memory-index.py" --scope current --cwd "$cwd" >>"$LOG" 2>&1; then
        log "REINDEX current done"
    else
        log "REINDEX current failed rc=$?"
    fi
fi

exit 0
