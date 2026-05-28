# GREEN validation scenarios

5 scenarios a subagent with ONLY the `antares-memory` skill loaded should be able to answer correctly.

## Scenario 1 — Save a feedback memory while in $HOME

**Prompt:**
> "Acabo de aprender que `paru` no acepta `--noconfirm` antes del `-S`. Debe ir después o el flag se ignora. Guárdalo para no volver a equivocarme."

**Expected:**

- Identifies that this is a `feedback_*` memory (a correction the operator wants persisted).
- Identifies that this is **HOME slug** scope (the `paru` quirk applies across all cwds).
- Proposes filename: `feedback_paru_noconfirm_position.md` (or similar — must use `feedback_` prefix and snake_case after).
- Proposes destination: `~/.claude/projects/<slugify($HOME)>/memory/` (e.g. `~/.claude/projects/-home-juan/memory/`).
- Proposes frontmatter with `name`, `description`, `type: feedback`.
- Body has a `**Why:**` line and a `**How to apply:**` line.
- Mentions that PostToolUse hook auto-reindexes the slug.

**Fail conditions:**
- Wrong prefix or type.
- Writes to `~/.claude/memory/` (the v0.1.x path).
- Suggests adding `@import` to `~/.claude/CLAUDE.md`.
- Writes to CURRENT slug when HOME makes more sense.

## Scenario 2 — Memory exists but isn't being recalled

**Prompt:**
> "Tengo una memoria sobre cómo funciona el SSH tunnel a MongoDB Compass, pero cuando le pregunto al asistente sobre eso, nunca aparece en el `<auto-loaded-memory>` block. ¿Qué chequeo?"

**Expected:**

1. `/antares-memory:status` first.
2. `tail $ANTARES_STATE/logs/memory-search.log` to see last hook activity.
3. Manual search with the CLI to verify the memory ranks:
   ```bash
   "$ANTARES_VENV_PY" "${CLAUDE_PLUGIN_ROOT}/scripts/memory-search.py" "mongodb compass ssh tunnel"
   ```
4. If the memory ranks below 0.35 threshold, suggest rewriting `description` to match the operator's wording.
5. If it doesn't rank at all, check whether it was indexed: query the SQLite DB at the matching slug's `.memory-index.db`.

**Fail conditions:**
- Goes straight to "the memory must not exist".
- Suggests rewriting before checking the daemon.
- Doesn't mention `/antares-memory:status` as first step.

## Scenario 3 — Consolidate memories from a legacy path

**Prompt:**
> "Tengo como 100 memorias en `~/.claude/memory/` (de la versión vieja). ¿Cómo las paso al sistema nuevo?"

**Expected:**

- Mentions `/antares-memory:migrate` as the tool — it auto-detects `~/.claude/memory/` as a legacy source.
- Default mode is **dry-run** — shows what will move without acting.
- The migrator skips files whose target name already exists in the HOME slug (no overwrite).
- Memories move to `~/.claude/projects/<slugify($HOME)>/memory/`.
- After migration the indexer auto-runs and the daemon picks up the new files.
- Mention: this is for the legacy single-path layout. In v0.2+, memories naturally live in the slug-based layout — no migration needed if the operator started fresh.

**Fail conditions:**
- Suggests a manual `mv` without using `migrate.sh`.
- Doesn't mention dry-run / `--apply` distinction.
- Recommends a path other than `~/.claude/projects/<slug>/memory/` as destination.

## Scenario 4 — Change the embedding model

**Prompt:**
> "Quiero probar `BAAI/bge-large-en-v1.5` en lugar del modelo multilingual default. ¿Cómo lo cambio?"

**Expected:**

1. Set `ANTARES_MODEL` env var (in the systemd unit's `Environment=` or `~/.config/environment.d/`).
2. Drop the embeddings from EVERY slug's DB (mixed dimensions = garbage results):
   ```bash
   for db in ~/.claude/projects/*/memory/.memory-index.db; do
       sqlite3 "$db" "DELETE FROM memory_chunks;"
   done
   ```
3. Restart the daemon.
4. Reindex HOME (other slugs reindex on their next session-start).
5. Note: `bge-large` is English-only — recall on Spanish prompts degrades.
6. Note: chunk size constant `TARGET_TOKENS` should ideally be bumped for the model's 512-token window.

**Fail conditions:**
- Suggests changing env var without dropping chunks.
- Drops chunks for only one slug.
- Doesn't mention the language mismatch.

## Scenario 5 — PreCompact extractor is expensive

**Prompt:**
> "Cada vez que mi sesión se compacta, veo en los logs que la extracción me cuesta como $0.40. ¿Cómo lo reduzco o lo apago si quiero?"

**Expected:**

Options laid out using **env vars** (no source edits needed — the script reads them):

1. Lower budget: `ANTARES_PRECOMPACT_BUDGET=0.20` in `~/.config/environment.d/antares-memory.conf` or similar.
2. Cheaper model: `ANTARES_PRECOMPACT_MODEL=haiku`.
3. Shorter timeout: `ANTARES_PRECOMPACT_TIMEOUT=120`.
4. **Disable entirely** — fork the plugin OR override the `PreCompact` hook in `~/.claude/settings.json` with an empty array (note: depending on Claude Code's hook merge semantics, this may or may not block the plugin's hook; experimentation needed).
5. Mention that partial writes before `BUDGET_EXCEEDED` are still kept.

**Fail conditions:**
- Suggests editing the script in plugin cache (which gets overwritten).
- Doesn't mention env vars as the first lever.
- Suggests deleting plugin files manually.

## How to run validation

Spawn a subagent with only the `antares-memory` skill loaded. For each scenario:

1. Paste the prompt.
2. Read the response.
3. Check it hits the expected points and avoids the fail conditions.
4. If any scenario fails, the SKILL.md and/or `reference/*.md` need a fix BEFORE publishing.
