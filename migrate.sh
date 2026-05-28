#!/usr/bin/env bash
# migrate.sh — move existing memories from ~/.claude/projects/<slug>/memory/
# into the antares-memory home ($CLAUDE_MEMORY_HOME, default ~/.claude/memory/).
#
# Safe by default: refuses to overwrite existing files. Prints a plan and
# requires explicit --apply to act.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

APPLY=false
SRC=""
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=true ;;
        --src=*) SRC="${arg#--src=}" ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--src=<dir>] [--apply]

By default, scans ~/.claude/projects/*/memory/ and prints a migration plan.
Add --apply to actually move the files. Use --src to point at a specific source.

Targets: \$CLAUDE_MEMORY_HOME = $CLAUDE_MEMORY_HOME
EOF
            exit 0
            ;;
    esac
done

# Detect source directory automatically if not provided.
if [[ -z "$SRC" ]]; then
    candidates=()
    while IFS= read -r d; do
        candidates+=("$d")
    done < <(find "$HOME/.claude/projects" -maxdepth 2 -type d -name memory 2>/dev/null)

    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo "No legacy memory dirs found under ~/.claude/projects/*/memory/"
        exit 0
    fi
    if [[ ${#candidates[@]} -gt 1 ]]; then
        echo "Multiple legacy memory dirs found. Specify one with --src=<path>:"
        printf '  %s\n' "${candidates[@]}"
        exit 1
    fi
    SRC="${candidates[0]}"
fi

if [[ ! -d "$SRC" ]]; then
    echo "Source not a directory: $SRC" >&2
    exit 1
fi

DST="$CLAUDE_MEMORY_HOME"
mkdir -p "$DST/journal"

printf '%sMigration plan%s\n' "$BOLD" "$RESET"
printf '  Source: %s\n' "$SRC"
printf '  Target: %s\n\n' "$DST"

moves=()
skips=()
conflicts=()

# Find .md files (incl. journal/) and SQLite index.
while IFS= read -r f; do
    rel="${f#$SRC/}"
    target="$DST/$rel"
    if [[ -e "$target" ]]; then
        conflicts+=("$rel")
    else
        moves+=("$rel")
    fi
done < <(find "$SRC" -type f \( -name '*.md' -o -name '.memory-index.db' \) 2>/dev/null)

if [[ ${#moves[@]} -gt 0 ]]; then
    printf '%sWill move %d file(s):%s\n' "$GREEN" "${#moves[@]}" "$RESET"
    for m in "${moves[@]}"; do printf '  + %s\n' "$m"; done
    echo
fi
if [[ ${#conflicts[@]} -gt 0 ]]; then
    printf '%sWill skip %d file(s) (already exist in target):%s\n' "$YELLOW" "${#conflicts[@]}" "$RESET"
    for c in "${conflicts[@]}"; do printf '  ~ %s\n' "$c"; done
    echo
fi

if ! $APPLY; then
    printf 'Dry-run only. Re-run with %s--apply%s to perform the migration.\n' "$BOLD" "$RESET"
    exit 0
fi

if [[ ${#moves[@]} -eq 0 ]]; then
    echo "Nothing to do."
    exit 0
fi

# Apply moves.
for rel in "${moves[@]}"; do
    src_f="$SRC/$rel"
    tgt_f="$DST/$rel"
    mkdir -p "$(dirname "$tgt_f")"
    mv -n "$src_f" "$tgt_f"
done
printf '\n%sMoved %d file(s).%s\n' "$GREEN" "${#moves[@]}" "$RESET"

# Reindex so the moved files are searchable.
if antares_venv_ready; then
    echo "Reindexing..."
    "$ANTARES_VENV_PY" "$SCRIPT_DIR/scripts/memory-index.py" --scope global || true
    echo "Done. Daemon will see the new files on the next query."
else
    echo "Venv not ready — run /antares-memory:install first, then reindex will happen automatically."
fi
