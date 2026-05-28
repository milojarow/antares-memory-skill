---
description: Remove the antares-memory daemon, venv, and state directory. Preserves your memory files in every slug dir. Asks for explicit confirmation before acting.
---

# Uninstall antares-memory

This removes the daemon, the Python venv, and logs/state — but **never** touches the user's memory files under `~/.claude/projects/<slug>/memory/`. Those are the user's data, distributed across every slug dir Claude Code has created for them.

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

1. Memory files still live at `~/.claude/projects/<slug>/memory/` across every cwd they've used with Claude Code. Their HOME slug (`~/.claude/projects/<slugify($HOME)>/memory/`) is the main one. Delete manually if they want them gone (use with care — every cwd has its own slug).
2. The plugin itself is still installed in Claude Code — remove it with `/plugin uninstall antares-memory-skill@antares-memory-skill`.
3. **No CLAUDE.md cleanup needed** in v0.2+ — the skill never added a `@`-import there in the first place.
