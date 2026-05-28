#!/usr/bin/env bash
# memory-reindex.sh — SessionStart hook: conditionally re-index memory embeddings.
# Reads cwd from stdin (SessionStart payload), reindexes the home + current
# slug dirs if any .md file is newer than the DB.
#
# Gracefully skips if the venv is not set up (operator hasn't run install yet).

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

# Helper: is any .md newer than the DB?
needs_reindex() {
    local mdir="$1"
    local db="$mdir/.memory-index.db"
    [[ -d "$mdir" ]] || return 1
    if [[ ! -f "$db" ]]; then
        # No DB yet — reindex if there's at least one .md
        [[ -n "$(find "$mdir" -name '*.md' -print -quit 2>/dev/null)" ]]
        return $?
    fi
    local db_mtime
    db_mtime=$(stat -c %Y "$db")
    while IFS= read -r -d '' file; do
        local file_mtime
        file_mtime=$(stat -c %Y "$file")
        (( file_mtime > db_mtime )) && return 0
    done < <(find "$mdir" -name '*.md' -print0 2>/dev/null)
    return 1
}

home_dir="$(antares_home_memory_dir)"
current_dir="$(antares_memory_dir_for "$cwd")"

# Index home if stale (or new).
if needs_reindex "$home_dir"; then
    "$ANTARES_VENV_PY" "$SCRIPT_DIR/memory-index.py" --scope home >&2 2>/dev/null || true
fi

# Index current if it's a different dir and stale.
if [[ "$current_dir" != "$home_dir" ]] && needs_reindex "$current_dir"; then
    "$ANTARES_VENV_PY" "$SCRIPT_DIR/memory-index.py" \
        --scope current --cwd "$cwd" >&2 2>/dev/null || true
fi

echo '{}'
exit 0
