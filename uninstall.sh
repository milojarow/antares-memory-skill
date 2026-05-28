#!/usr/bin/env bash
# uninstall.sh — remove daemon, venv, logs.
# DOES NOT touch $CLAUDE_MEMORY_HOME (your memory files). Those are yours.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

confirm=${1:-}
if [[ "$confirm" != "--yes" ]]; then
    cat <<EOF
${BOLD}This will remove:${RESET}
  - Daemon: ~/.config/systemd/user/antares-memory-daemon.service
  - Venv:   $ANTARES_VENV
  - Logs:   $ANTARES_STATE

${BOLD}This will NOT touch:${RESET}
  - $CLAUDE_MEMORY_HOME  (your memory files — preserved)

Re-run with --yes to confirm:
  bash "$0" --yes
EOF
    exit 1
fi

echo "Stopping daemon..."
systemctl --user disable --now antares-memory-daemon.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/antares-memory-daemon.service"
systemctl --user daemon-reload 2>/dev/null || true
printf '%s✓%s daemon removed\n' "$GREEN" "$RESET"

echo "Removing venv at $ANTARES_VENV..."
rm -rf "$ANTARES_VENV"
printf '%s✓%s venv removed\n' "$GREEN" "$RESET"

echo "Removing state dir $ANTARES_STATE..."
rm -rf "$ANTARES_STATE"
printf '%s✓%s state removed\n' "$GREEN" "$RESET"

echo
printf '%sYour memory files remain at:%s %s\n' "$YELLOW" "$RESET" "$CLAUDE_MEMORY_HOME"
printf '%sDelete them manually if you also want them gone:%s\n' "$YELLOW" "$RESET"
printf '  rm -rf "%s"\n' "$CLAUDE_MEMORY_HOME"
echo
echo "Finish the cleanup by removing the plugin in Claude Code:"
echo "  /plugin uninstall antares-memory-skill@antares-memory-skill"
