# antares-memory-skill

**Persistent semantic + keyword memory for Claude Code — turnkey.**

## What is this?

A complete memory system for Claude Code that survives across sessions: the assistant writes lessons, gotchas, and decisions to disk as `.md` files; a hybrid search daemon (embeddings + BM25) makes them recallable; relevant memories auto-inject on every prompt; and on context compaction, a headless `claude -p` extracts new memories from the transcript before history is lost.

Everything ships in one plugin. After `/antares-memory:install`, you get:

- **Storage** at `~/.claude/memory/` — flat directory of `.md` files with frontmatter taxonomy (`feedback_*`, `reference_*`, `project_*`, `user_*`, `tool_*`)
- **Indexer** (`sentence-transformers` multilingual model) chunking files and storing embeddings in SQLite
- **Search daemon** — UNIX socket, model pre-warmed in RAM, hybrid cosine + BM25
- **4 hooks** wired automatically (UserPromptSubmit, SessionStart, PreCompact, PostToolUse)
- **Journal** (`memory/journal/YYYY-MM-DD.md`) loaded at session start
- **Project scope** — drop `.claude/memory/` in any repo to layer project-only memories

### Why this skill exists

- **Cross-session knowledge has to be re-derived every conversation otherwise.** A flat `CLAUDE.md` doesn't scale past a few dozen rules.
- **Semantic recall beats keyword grep.** Hybrid search (70% cosine + 30% BM25) finds memories you didn't know to look for.
- **PreCompact is the only moment the transcript is still in memory.** A headless extractor at that point captures lessons that would otherwise be lost when context compresses.
- **Daemon keeps the model warm.** First search after install is slow (model load); subsequent searches are sub-100ms.
- **Plugin-hosted hooks survive `settings.json` rewrites.** Auto-update through marketplace just works.

## The skill

| Skill | Description |
|-------|-------------|
| **antares-memory** | When to write a memory, where (global vs project), frontmatter taxonomy, tuning the search, troubleshooting the daemon, and operating the `/antares-memory:*` commands |

## Installation

Add the marketplace in Claude Code:

```
/plugin marketplace add milojarow/antares-memory-skill
```

Install the plugin:

```
/plugin install antares-memory-skill@antares-memory-skill
```

Run the one-time setup (creates venv, downloads the embedding model ~400MB, enables systemd daemon):

```
/antares-memory:install
```

Add this line to your `~/.claude/CLAUDE.md` so the memory index is always-loaded:

```
@~/.claude/memory/MEMORY.md
```

Done. Open a new session — your next `UserPromptSubmit` will hit the daemon and inject relevant memories.

## Commands

| Command | Purpose |
|---|---|
| `/antares-memory:install` | One-time setup: venv, model, daemon, dirs. Idempotent. |
| `/antares-memory:status` | Diagnose daemon, index, hook health. |
| `/antares-memory:migrate` | Move memories from `~/.claude/projects/<slug>/memory/` to `~/.claude/memory/`. |
| `/antares-memory:uninstall` | Remove daemon, venv, dirs. Preserves `~/.claude/memory/` (your data). |

## Requirements

- Linux with systemd user instance (or macOS with launchd — daemon falls back to manual `python3 daemon.py &`)
- `python3 >= 3.10`, `jq`, `socat`, `sqlite3` (with FTS5)
- ~400 MB disk for the multilingual embedding model
- ~1.5 GB RAM for the daemon (model + index)

## License

MIT
