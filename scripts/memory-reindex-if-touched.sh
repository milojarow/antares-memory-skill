#!/usr/bin/env bash
# PostToolUse hook — if a Write/Edit/MultiEdit touched a memory .md file
# (anywhere under ~/.claude/projects/<slug>/memory/), trigger an incremental
# reindex in the background so the new content is searchable by the
# UserPromptSubmit hook within the same session.
#
# Failsafe: any error → exit 0, never block the tool flow.

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

# Match: $ANTARES_PROJECTS_DIR/<slug>/memory/...
# That means the parent of the file is somewhere under a slug's memory/ dir.
case "$file_path" in
  "$ANTARES_PROJECTS_DIR"/*/memory/*) ;;
  *) exit 0 ;;
esac

# Extract slug → reconstruct the original cwd to pass to the indexer.
# Path structure: $ANTARES_PROJECTS_DIR/<slug>/memory/<rest>
rest="${file_path#"$ANTARES_PROJECTS_DIR"/}"   # <slug>/memory/<rest>
slug="${rest%%/memory/*}"

# Reverse slugify: '-' → '/'. Lossy at edges; for our use the recovered cwd
# only needs to make memory_dir_for(cwd) match the original slug, which the
# indexer recomputes anyway. We just need ANY cwd that slugifies to <slug>.
cwd="/${slug//-/'/'}"
cwd="${cwd//\/\//\/}"   # collapse accidental double slashes

# Skip MEMORY.md itself (always-loaded index, not indexed content).
[[ "$(basename "$file_path")" == "MEMORY.md" ]] && exit 0

# Skip backups, SQLite DB itself, non-md files.
case "$file_path" in
  *.bak*|*.db|*.db-*|*.db.*) exit 0 ;;
esac
[[ "$file_path" == *.md ]] || exit 0

# Async reindex of just the affected slug. We pass --cwd so the indexer
# resolves the same slug dir on its own.
{
  printf '[%s] reindex slug=%s triggered by %s\n' \
    "$(date -Iseconds)" "$slug" "$file_path" >>"$LOG"
  "$ANTARES_VENV_PY" "$SCRIPT_DIR/memory-index.py" \
    --scope current --cwd "$cwd" >>"$LOG" 2>&1
  printf '[%s] reindex done slug=%s\n' "$(date -Iseconds)" "$slug" >>"$LOG"
} </dev/null >/dev/null 2>&1 &
disown

exit 0
