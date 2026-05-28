#!/usr/bin/env bash
# PostToolUse hook — if a Write/Edit/MultiEdit touched a memory .md file,
# trigger an incremental reindex in the background so the new content is
# searchable by the UserPromptSubmit hook within the same session.
#
# Failsafe: any error → exit 0, never block the tool flow.

# Re-entrancy guard: skip when invoked from a headless sub-claude (PreCompact).
[[ -n "${CLAUDE_HEADLESS:-}" ]] && exit 0

trap 'exit 0' ERR
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

LOG="$ANTARES_STATE/logs/memory-reindex-auto.log"

if ! antares_venv_ready; then
    exit 0
fi

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)

[[ -z "$file_path" ]] && exit 0

# Determine scope from path:
#   - $CLAUDE_MEMORY_HOME/...   → global scope
#   - <PROJ>/.claude/memory/... → project scope, project root = <PROJ>
scope=""
project_root=""
case "$file_path" in
  "$CLAUDE_MEMORY_HOME"/*)
    scope="global"
    ;;
  */.claude/memory/*)
    project_root="${file_path%/.claude/memory/*}"
    [[ -n "$project_root" && -d "$project_root/.claude/memory" ]] && scope="project"
    ;;
esac

[[ -z "$scope" ]] && exit 0

# Skip MEMORY.md itself (always-loaded index, not indexed content).
[[ "$(basename "$file_path")" == "MEMORY.md" ]] && exit 0

# Skip backups, SQLite DB itself, non-md files.
case "$file_path" in
  *.bak*|*.db|*.db-*|*.db.*) exit 0 ;;
esac
[[ "$file_path" == *.md ]] || exit 0

# Async reindex of just the affected scope. memory-index.py is idempotent
# and only re-embeds files with mtime > stored, so racing PostToolUse hooks
# coalesce naturally.
{
  printf '[%s] reindex scope=%s root=%s triggered by %s\n' \
    "$(date -Iseconds)" "$scope" "${project_root:-N/A}" "$file_path" >>"$LOG"
  cwd_arg=()
  [[ -n "$project_root" ]] && cwd_arg=(--cwd "$project_root")
  "$ANTARES_VENV_PY" "$SCRIPT_DIR/memory-index.py" \
    --scope "$scope" "${cwd_arg[@]}" >>"$LOG" 2>&1
  printf '[%s] reindex done scope=%s\n' "$(date -Iseconds)" "$scope" >>"$LOG"
} </dev/null >/dev/null 2>&1 &
disown

exit 0
