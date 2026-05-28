---
description: Consolidate stragglers from a non-standard path (legacy v0.1.x ~/.claude/memory/, an old slug dir, etc.) into the HOME slug. Dry-runs by default; requires explicit user approval before --apply.
---

# Migrate memories into the HOME slug

In v0.2+, memories naturally live at `~/.claude/projects/<slugify(cwd)>/memory/` — Claude Code's native convention. **You usually don't need this command.** It's for the edge case where the user has memories somewhere else they want consolidated into the HOME slug.

First run a dry-run to show what will move:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/migrate.sh"
```

The script auto-detects `~/.claude/memory/` as a legacy v0.1.x source. If you want a different source:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/migrate.sh" --src=/some/path
```

The output lists files that will move (green `+`) and files that will be skipped because they already exist in the target (yellow `~`).

**Show the plan to the user and wait for explicit approval** before applying. Migration is a `mv` (not a copy).

If the user approves, apply:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/migrate.sh" --apply
```

The migrate script reindexes the HOME slug automatically. Confirm with the user that:

1. The expected file count moved.
2. `/antares-memory:status` shows the new SQLite index size in the HOME slug.
3. Test a recall: pose a question that matches one of the migrated memories — the `<auto-loaded-memory>` block should include it.
