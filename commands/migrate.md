---
description: Move existing memories from ~/.claude/projects/<slug>/memory/ into ~/.claude/memory/ (the antares-memory home). Always dry-runs first; requires explicit user approval before --apply.
---

# Migrate legacy memories

First run a dry-run to show what will move:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/migrate.sh"
```

The output lists files that will move (green `+`) and files that will be skipped because they already exist in the target (yellow `~`).

**Show the plan to the user and wait for explicit approval** before applying. Migration is a `mv` (not a copy) — the source dir loses the files.

If the user approves, apply:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/migrate.sh" --apply
```

After applying, the migrate script automatically reindexes so the daemon picks up the new files. Confirm with the user that:

1. The expected file count moved.
2. `/antares-memory:status` shows the new SQLite index size.
3. Test a recall: pose a question that matches one of the migrated memories — the `<auto-loaded-memory>` block should include it.

If the user has memories under a non-standard path, pass `--src=<path>` to the script.
