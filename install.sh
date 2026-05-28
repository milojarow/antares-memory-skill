#!/usr/bin/env bash
# install.sh — one-time setup for antares-memory-skill.
#
# Idempotent. Safe to re-run. Reads env vars from scripts/lib/common.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

say()  { printf '%s%s%s\n'  "$BOLD" "$*" "$RESET"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '%s✗%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

say "antares-memory-skill installer"
echo

# ─── 1. Dependency check ──────────────────────────────────────────────────────
say "1/7  Checking dependencies"
for cmd in python3 jq socat sqlite3 systemctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "Missing required command: $cmd"
    fi
done
py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
py_major=$(echo "$py_ver" | cut -d. -f1)
py_minor=$(echo "$py_ver" | cut -d. -f2)
if (( py_major < 3 )) || { (( py_major == 3 )) && (( py_minor < 10 )); }; then
    die "python3 >= 3.10 required (have $py_ver)"
fi
if ! systemctl --user status >/dev/null 2>&1 \
   && ! systemctl --user --version >/dev/null 2>&1; then
    warn "systemctl --user is not available — daemon will need manual launch"
fi
ok "deps present (python $py_ver, jq, socat, sqlite3, systemctl)"

# ─── 2. Create directories ────────────────────────────────────────────────────
say "2/7  Creating directories"
mkdir -p "$CLAUDE_MEMORY_HOME/journal"
mkdir -p "$ANTARES_STATE/logs"
mkdir -p "$(dirname "$ANTARES_VENV")"
ok "$CLAUDE_MEMORY_HOME (memory store)"
ok "$ANTARES_STATE (logs)"

# ─── 3. Seed MEMORY.md ────────────────────────────────────────────────────────
say "3/7  Seeding MEMORY.md (only if missing)"
MEMORY_INDEX="$CLAUDE_MEMORY_HOME/MEMORY.md"
if [[ ! -f "$MEMORY_INDEX" ]]; then
    cat > "$MEMORY_INDEX" <<'EOF'
# Memory — Always-on directives

These rules apply across ALL domains and stay loaded for every session.
Domain-specific memories auto-load via the `UserPromptSubmit` hook by
semantic similarity. List below the few entries you want always-loaded
regardless of the current prompt.

Format: one line per entry.

- (no entries yet — add your own as you accumulate memories)
EOF
    ok "wrote initial $MEMORY_INDEX"
else
    ok "$MEMORY_INDEX already exists — left as is"
fi

# ─── 4. Python venv + deps ────────────────────────────────────────────────────
say "4/7  Setting up Python venv (this downloads ~400MB on first run)"
if [[ ! -x "$ANTARES_VENV_PY" ]]; then
    python3 -m venv "$ANTARES_VENV"
    ok "created venv at $ANTARES_VENV"
else
    ok "venv exists at $ANTARES_VENV"
fi

"$ANTARES_VENV/bin/pip" install --quiet --upgrade pip

if ! "$ANTARES_VENV_PY" -c "import sentence_transformers" 2>/dev/null; then
    echo "    Installing sentence-transformers (+ torch CPU)..."
    "$ANTARES_VENV/bin/pip" install --quiet \
        --index-url https://download.pytorch.org/whl/cpu \
        --extra-index-url https://pypi.org/simple \
        sentence-transformers numpy
    ok "installed sentence-transformers"
else
    ok "sentence-transformers already installed"
fi

# Pre-download the embedding model so the first daemon start isn't slow.
echo "    Pre-downloading model $ANTARES_MODEL..."
"$ANTARES_VENV_PY" - <<PY
from sentence_transformers import SentenceTransformer
SentenceTransformer("$ANTARES_MODEL")
PY
ok "model $ANTARES_MODEL cached"

# ─── 5. systemd user unit ─────────────────────────────────────────────────────
say "5/7  Installing systemd user unit"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/antares-memory-daemon.service"
mkdir -p "$UNIT_DIR"

DAEMON_SCRIPT="$SCRIPT_DIR/scripts/memory-search-daemon.py"

# Render the template — substitute @VAR@ placeholders with absolute paths.
sed \
    -e "s|@ANTARES_VENV_PY@|$ANTARES_VENV_PY|g" \
    -e "s|@ANTARES_DAEMON_SCRIPT@|$DAEMON_SCRIPT|g" \
    -e "s|@ANTARES_MODEL@|$ANTARES_MODEL|g" \
    -e "s|@CLAUDE_MEMORY_HOME@|$CLAUDE_MEMORY_HOME|g" \
    -e "s|@ANTARES_STATE@|$ANTARES_STATE|g" \
    "$SCRIPT_DIR/systemd/antares-memory-daemon.service.tmpl" \
    > "$UNIT_FILE"
ok "wrote $UNIT_FILE"

systemctl --user daemon-reload
systemctl --user enable --now antares-memory-daemon.service
sleep 1
if systemctl --user is-active --quiet antares-memory-daemon.service; then
    ok "daemon running"
else
    warn "daemon not active — run 'systemctl --user status antares-memory-daemon' for details"
fi

# ─── 6. First-time index pass ─────────────────────────────────────────────────
say "6/7  Running first index pass"
"$ANTARES_VENV_PY" "$SCRIPT_DIR/scripts/memory-index.py" --scope global || true
ok "index ready"

# ─── 7. Final notes ───────────────────────────────────────────────────────────
say "7/7  Done!"
echo
cat <<EOF
${BOLD}Next steps:${RESET}

  1. Add this line to your ${BOLD}~/.claude/CLAUDE.md${RESET} so the memory index is always-loaded:

       ${GREEN}@$CLAUDE_MEMORY_HOME/MEMORY.md${RESET}

  2. Open a new Claude Code session. Your next prompt will hit the daemon
     and auto-load relevant memories via the UserPromptSubmit hook.

  3. Diagnose anytime: ${GREEN}/antares-memory:status${RESET}

  4. Already have memories under ~/.claude/projects/<slug>/memory/ that you
     want to migrate? Run: ${GREEN}/antares-memory:migrate${RESET}

EOF
