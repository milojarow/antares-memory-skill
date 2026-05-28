---
description: One-time setup for antares-memory — creates venv, downloads the embedding model, installs the systemd daemon, seeds the memory dir. Idempotent.
---

# Install antares-memory

Run the installer:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/install.sh"
```

The installer is idempotent — running it again only re-applies missing pieces. It checks dependencies, sets up the Python venv (downloads ~400 MB on first run for the embedding model), enables the systemd user daemon, and prints the line to add to `~/.claude/CLAUDE.md`.

After it finishes, summarize for the user:

1. Was the daemon enabled? (`systemctl --user status antares-memory-daemon`)
2. Did they need to add the `@~/.claude/memory/MEMORY.md` line to `~/.claude/CLAUDE.md` yet?
3. Did the installer emit any warnings worth flagging?

If anything failed, point the user to `${ANTARES_STATE:-$HOME/.local/state/antares-memory}/logs/` for detail.
