# GREEN validation scenarios

5 scenarios a subagent with ONLY the `antares-memory` skill loaded should be able to answer correctly. Each lists: the prompt, the expected response shape, and what counts as a fail.

## Scenario 1 — Save a feedback memory

**Prompt:**
> "Acabo de aprender que `paru` no acepta `--noconfirm` antes del `-S`. Debe ir después o el flag se ignora. Guárdalo para no volver a equivocarme."

**Expected:**

- Identifies that this is a `feedback_*` memory (a correction the operator wants persisted).
- Identifies that this is **global** scope (the `paru` quirk applies across all projects).
- Proposes filename: `feedback_paru_noconfirm_position.md` (or similar — must use `feedback_` prefix and snake_case after).
- Proposes destination: `~/.claude/memory/` (or `$CLAUDE_MEMORY_HOME`).
- Proposes frontmatter with `name`, `description`, `type: feedback`.
- Body has a `**Why:**` line and a `**How to apply:**` line.
- Mentions that the PostToolUse hook will auto-reindex once the file is written.

**Fail conditions:**
- Wrong prefix or type (e.g., `tool_paru_*` or `reference_paru_*`).
- Suggests project scope.
- Writes to `~/.claude/projects/<something>/memory/` (legacy path).
- No frontmatter, or invalid type value.

## Scenario 2 — Memory exists but isn't being recalled

**Prompt:**
> "Tengo una memoria sobre cómo funciona el SSH tunnel a MongoDB Compass, pero cuando le pregunto al asistente sobre eso, nunca aparece en el `<auto-loaded-memory>` block. ¿Qué chequeo?"

**Expected:**

A diagnostic walk in order:

1. `/antares-memory:status` first.
2. `tail $ANTARES_STATE/logs/memory-search.log` to see last hook activity (looking for `DAEMON_DOWN`, `TIMEOUT`, `NOHITS`, or `OK`).
3. Manual search with the CLI to verify the memory ranks at all:
   ```bash
   "$ANTARES_VENV_PY" "${CLAUDE_PLUGIN_ROOT}/scripts/memory-search.py" "mongodb compass ssh tunnel"
   ```
4. If the memory ranks below 0.35 threshold, suggest either (a) rewriting the `description` field to match the operator's wording, or (b) lowering the threshold experimentally.
5. If the memory doesn't rank at all, check whether it was indexed: query the SQLite DB.

**Fail conditions:**
- Goes straight to "the memory must not exist" without checking the index.
- Suggests rewriting the memory before checking the daemon.
- Doesn't mention `/antares-memory:status` as the first step.

## Scenario 3 — Migrate legacy memories

**Prompt:**
> "Tengo como 100 memorias en `~/.claude/projects/-home-foo/memory/`. ¿Cómo las paso al sistema nuevo?"

**Expected:**

- Mentions `/antares-memory:migrate` as the tool.
- Explains that the default mode is **dry-run** — shows what will move without acting.
- Explicitly notes: the script will skip files whose target name already exists (no overwrite).
- Mentions the source can be specified with `--src=<path>` if it's not at the default `~/.claude/projects/*/memory/` location.
- Recommends running dry-run first, reviewing the plan, then `--apply`.
- Mentions that after migration the indexer auto-runs and the daemon picks up the new files.

**Fail conditions:**
- Suggests a manual `mv` or `cp` (skips the validation that `migrate.sh` provides).
- Doesn't mention the dry-run / `--apply` distinction.
- Suggests deleting the legacy directory before confirming the move.

## Scenario 4 — Change the embedding model

**Prompt:**
> "Quiero probar `BAAI/bge-large-en-v1.5` en lugar del modelo multilingual default. ¿Cómo lo cambio?"

**Expected:**

A multi-step recipe:

1. Set `ANTARES_MODEL=BAAI/bge-large-en-v1.5` in the daemon unit (`Environment=` line) or as an env var if running ad-hoc.
2. **Drop existing chunks** — old embeddings are in a different vector space:
   ```bash
   sqlite3 "$CLAUDE_MEMORY_HOME/.memory-index.db" "DELETE FROM memory_chunks;"
   ```
3. Reindex from scratch with the new model.
4. Restart the daemon to load the new model.
5. Note: `bge-large` is English-only — if the operator writes memories in Spanish, recall quality will drop.
6. Note: `bge-large` has a 512-token max-sequence — if not updating `TARGET_TOKENS` in the indexer, some content fits in fewer chunks (which is fine), but the chunk size is suboptimal.

**Fail conditions:**
- Suggests just changing the env var without dropping chunks.
- Doesn't mention the language mismatch (multilingual → English-only).
- Suggests editing source code without identifying which file/constant.

## Scenario 5 — PreCompact extractor is expensive

**Prompt:**
> "Cada vez que mi sesión se compacta, veo en los logs que la extracción me cuesta como $0.40. ¿Cómo lo reduzco o lo apago si quiero?"

**Expected:**

Options laid out:

1. **Cap the budget lower** — edit `memory-precompact-extract.sh`, change `--max-budget-usd 1.00` to `0.20` (or whatever). Trade-off: the sub-claude may exit before finishing extraction; partial writes are still kept.
2. **Switch model** — already on `sonnet` (cheap). Going to `haiku` would be cheaper but extraction quality drops. Not recommended unless cost is critical.
3. **Disable extraction entirely** — remove the `PreCompact` block from `hooks/hooks.json` (requires forking or wrapping; since hooks come from the plugin, the cleaner option is to override at the operator's `~/.claude/settings.json` level with an empty `PreCompact` array — Claude Code merges these and the explicit empty wins... actually, the correct approach is to disable the plugin's PreCompact via `disabledPluginHooks` if that setting exists, otherwise the operator has to fork.
4. **Pre-cap transcript size** — the script already caps at 100 KB. Going lower means even less context for the sub-claude → faster + cheaper.
5. **Run extraction selectively** — currently fires on every compact. No way to filter (e.g., "only on auto, not manual") without editing the script — the matcher is `manual|auto`.

**Fail conditions:**
- Suggests the user just delete the script (it lives in plugin cache — gets restored on update).
- Doesn't mention the budget cap as the simplest knob.
- Doesn't acknowledge that turning extraction off entirely is a real choice — some operators won't use it.

## How to run validation

Spawn a subagent with only the `antares-memory` skill loaded. For each scenario:

1. Paste the prompt.
2. Read the response.
3. Check it hits the expected points and avoids the fail conditions.
4. If any scenario fails, the SKILL.md and/or `reference/*.md` need a fix BEFORE the skill is published.
