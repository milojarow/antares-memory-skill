#!/usr/bin/env bash
# memory-reindex.sh — SessionStart hook: conditionally re-index memory embeddings.
# Reads cwd from stdin (SessionStart payload), reindexes global + project scope
# if cwd has a project root with .claude/memory/. Per-scope freshness is decided
# by the Python indexer (file mtime vs stored mtime).
#
# Gracefully skips if the venv is not set up (operator hasn't run install yet).

# Re-entrancy guard: skip when invoked from a headless sub-claude (PreCompact).
[[ -n "${CLAUDE_HEADLESS:-}" ]] && { echo '{}'; exit 0; }

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if ! antares_venv_ready; then
    echo '{}'
    exit 0
fi

# Read cwd from SessionStart hook payload (best-effort; defaults to $PWD).
input=""
if [[ -p /dev/stdin || ! -t 0 ]]; then
    input=$(cat)
fi
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$cwd" ]] && cwd="$PWD"

GLOBAL_DB="$CLAUDE_MEMORY_HOME/.memory-index.db"

needs_global_reindex=true
if [[ -f "$GLOBAL_DB" ]]; then
    db_mtime=$(stat -c %Y "$GLOBAL_DB")
    needs_global_reindex=false
    while IFS= read -r -d '' file; do
        file_mtime=$(stat -c %Y "$file")
        if (( file_mtime > db_mtime )); then
            needs_global_reindex=true
            break
        fi
    done < <(find "$CLAUDE_MEMORY_HOME" -name '*.md' -print0 2>/dev/null)
fi

if [[ "$needs_global_reindex" == "true" ]]; then
    "$ANTARES_VENV_PY" "$SCRIPT_DIR/memory-index.py" --scope global >&2 2>/dev/null || true
fi

# Project scope — let the Python indexer figure out if cwd has one. If not,
# get_scopes returns empty for project and the call exits cleanly.
"$ANTARES_VENV_PY" "$SCRIPT_DIR/memory-index.py" \
    --scope project --cwd "$cwd" >&2 2>/dev/null || true

echo '{}'
exit 0
