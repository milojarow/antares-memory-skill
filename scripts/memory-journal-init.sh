#!/usr/bin/env bash
# memory-journal-init.sh — SessionStart hook: create today's journal file
# and inject today's + yesterday's journal content as additionalContext.

# Re-entrancy guard: skip when invoked from a headless sub-claude (PreCompact).
[[ -n "${CLAUDE_HEADLESS:-}" ]] && { echo '{}'; exit 0; }

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

JOURNAL_DIR="$CLAUDE_MEMORY_HOME/journal"
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -d 'yesterday' +%Y-%m-%d)
TODAY_FILE="$JOURNAL_DIR/$TODAY.md"
YESTERDAY_FILE="$JOURNAL_DIR/$YESTERDAY.md"
MAX_TODAY=15000
MAX_YESTERDAY=8000

mkdir -p "$JOURNAL_DIR" 2>/dev/null || { echo '{}'; exit 0; }

if [[ ! -f "$TODAY_FILE" ]]; then
    cat > "$TODAY_FILE" <<EOF
# Journal: $TODAY

## Sessions

EOF
fi

context=""

# Yesterday's journal (if it exists and has meaningful content).
if [[ -f "$YESTERDAY_FILE" ]] && [[ -s "$YESTERDAY_FILE" ]] && (( $(wc -c < "$YESTERDAY_FILE") > 50 )); then
    yesterday_content=$(head -c "$MAX_YESTERDAY" "$YESTERDAY_FILE")
    (( $(wc -c < "$YESTERDAY_FILE") > MAX_YESTERDAY )) && yesterday_content+=$'\n[... truncated for context efficiency ...]'
    context="<journal-yesterday>"$'\n'"$yesterday_content"$'\n'"</journal-yesterday>"$'\n'
fi

# Today's journal.
if [[ -s "$TODAY_FILE" ]] && (( $(wc -c < "$TODAY_FILE") > 50 )); then
    today_content=$(head -c "$MAX_TODAY" "$TODAY_FILE")
    (( $(wc -c < "$TODAY_FILE") > MAX_TODAY )) && today_content+=$'\n[... truncated for context efficiency ...]'
    context+="<journal-today>"$'\n'"$today_content"$'\n'"</journal-today>"
fi

if [[ -z "$context" ]]; then
    echo '{}'
    exit 0
fi

escape_for_json() {
    local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}";
    s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"; printf '%s' "$s"
}

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
    "$(escape_for_json "$context")"
exit 0
