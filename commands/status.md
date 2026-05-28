---
description: Diagnostic snapshot of antares-memory — daemon health, index size, log tails, paths, venv. Use when the auto-loaded memory block stops appearing or the daemon is suspect.
---

# antares-memory status

Run the diagnostic:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/status.sh"
```

Read the output and surface anything red (✗) to the user with a concrete fix:

| Symptom | Fix |
|---|---|
| Venv not ready | `/antares-memory:install` |
| Daemon not active | `systemctl --user start antares-memory-daemon` |
| Socket not responding to ping | Restart the daemon: `systemctl --user restart antares-memory-daemon` |
| No SQLite index | First reindex auto-fires when any `.md` is added — or trigger manually with the indexer (see `${CLAUDE_PLUGIN_ROOT}/scripts/memory-index.py`) |
| MEMORY.md missing | Re-run `/antares-memory:install` (it seeds the file when missing, never overwrites) |

Yellow (!) lines are informational — surface only if relevant to the user's question.
