# Tuning the search

## Defaults

| Knob | Default | Tunable how |
|---|---|---|
| Model | `paraphrase-multilingual-MiniLM-L12-v2` | env var `ANTARES_MODEL` |
| Cosine weight | 0.7 | `--vector-weight` (CLI) or `vector_weight` (daemon JSON) |
| BM25 weight | 0.3 | `--keyword-weight` or `keyword_weight` |
| Min score threshold | 0.35 | `--threshold` or `threshold` |
| Top-K | 5 | `--top-n` or `top_k` |
| Chunk target tokens | 120 | source constant `TARGET_TOKENS` in `memory-index.py` |
| Chunk overlap | 30 | source constant `OVERLAP_TOKENS` |

## When to lower the threshold

The `UserPromptSubmit` hook uses `0.35` by default. If you find relevant memories that ARE in the store but aren't being injected:

```bash
# Try a lower threshold from the CLI to confirm the memory ranks
"$ANTARES_VENV_PY" "${CLAUDE_PLUGIN_ROOT}/scripts/memory-search.py" \
    "your test query" --threshold 0.2
```

If the memory shows up at `0.2` but not `0.35`, your memory's content doesn't lexically/semantically match the prompt strongly enough. Options:

1. **Rewrite the memory's `description`** to use words the operator naturally uses when the topic comes up.
2. **Lower the threshold globally** (requires editing the source — there's no env var for it yet). Be careful: too low = noise.
3. **Add to `MEMORY.md`** if it should be always-loaded regardless of similarity.

## When to raise the threshold

If `<auto-loaded-memory>` blocks are noisy (5 random hits per prompt), raise to 0.4–0.45.

## Weighting cosine vs BM25

The default 70/30 favors semantic recall. Two cases to flip:

- **Exact-name lookups** (the user asks about a specific tool, file, or function by name): boost BM25 weight to 0.5–0.6 temporarily. Use case: searching for `meta-ads CLI` and you want the `tool_meta_ads_cli.md` exact filename match prioritized.

- **Concept queries** (the user asks "how do I handle X" where X is vague): keep cosine high (0.7+). Embeddings find conceptually related memories the operator may have forgotten about.

## Swapping the embedding model

The default works well for ES + EN mixed content. Other options:

| Model | Strengths | Trade-offs |
|---|---|---|
| `paraphrase-multilingual-MiniLM-L12-v2` (default) | Multilingual, fast, 384 dim | 128-token window |
| `all-MiniLM-L6-v2` | English-only, fastest, 384 dim | English-only, 256-token window |
| `BAAI/bge-large-en-v1.5` | Higher quality English, 1024 dim | English-only, slower, 512-token window |
| `intfloat/multilingual-e5-large` | Best multilingual quality, 1024 dim | Slower, 512-token window, more RAM |

To swap:

1. Set `ANTARES_MODEL` env var (or edit the systemd unit's `Environment=ANTARES_MODEL=...`).
2. **Drop the embeddings** from the SQLite DB (different model = different embedding space):
   ```bash
   sqlite3 "$CLAUDE_MEMORY_HOME/.memory-index.db" "DELETE FROM memory_chunks;"
   ```
3. Restart the daemon: `systemctl --user restart antares-memory-daemon`.
4. Trigger a full reindex:
   ```bash
   "$ANTARES_VENV_PY" "${CLAUDE_PLUGIN_ROOT}/scripts/memory-index.py" --scope global
   ```
5. If the new model's max-seq-length is different from 128, edit `TARGET_TOKENS` in `memory-index.py` to stay under the new limit (e.g., 240 for a 256-token model).

## Adjusting chunk size

Default chunks are ~120 tokens with 30-token overlap — sized for the default model's 128-token max. Trade-offs:

- **Smaller chunks** (e.g., 60 tokens) → more chunks per file → more granular retrieval → noisier results, more DB rows.
- **Larger chunks** (e.g., 240 with a bigger-context model) → fewer chunks → less granular but each chunk is more informative.

If you change chunk size, drop all chunks and reindex — old chunks will have mismatched token counts.

## Top-K

The hook injects `top_k=5`. Trade-offs:

- **Higher K** (e.g., 10): more context, but each prompt costs more tokens (each memory file is included full).
- **Lower K** (e.g., 3): cheaper but more likely to miss a relevant memory.

To change for the hook, edit `scripts/memory-search-hook.sh` (the `top_k:5` literal in the JSON request).

## Verifying a tuning change

```bash
# Direct CLI query — no daemon, full output
"$ANTARES_VENV_PY" "${CLAUDE_PLUGIN_ROOT}/scripts/memory-search.py" \
    "your query" \
    --threshold 0.3 \
    --vector-weight 0.6 \
    --keyword-weight 0.4 \
    --top-n 10

# Or via the daemon (faster — model already loaded)
echo '{"op":"search","query":"your query","top_k":10,"threshold":0.3,
       "vector_weight":0.6,"keyword_weight":0.4}' \
  | socat - "UNIX-CONNECT:$XDG_RUNTIME_DIR/memory-search.sock"
```

The daemon path is what the hook uses, so test there before tweaking source code.
