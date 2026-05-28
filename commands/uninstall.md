---
description: Remove the antares-memory daemon, venv, and state directory. Preserves your memory files. Asks for explicit confirmation before acting.
---

# Uninstall antares-memory

This removes the daemon, the Python venv, and logs/state — but **never** touches the user's memory files at `$CLAUDE_MEMORY_HOME` (default `~/.claude/memory/`). Those are the user's data.

First, show the dry-run with what will be removed and what will be preserved:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/uninstall.sh"
```

The script prints the plan and exits. **Wait for explicit confirmation** from the user before proceeding.

If confirmed:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/uninstall.sh" --yes
```

After that runs, remind the user:

1. Memory files still live at `~/.claude/memory/` (or their `$CLAUDE_MEMORY_HOME`). Delete manually if they want them gone.
2. The plugin itself is still installed in Claude Code — remove it with `/plugin uninstall antares-memory-skill@antares-memory-skill`.
3. If they added `@~/.claude/memory/MEMORY.md` to `~/.claude/CLAUDE.md`, that line can stay (harmless) or be removed.
