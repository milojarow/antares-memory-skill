#!/usr/bin/env python3
"""Memory embedding indexer with paragraph-aware chunking.

Reads all .md files in a memory directory (including journal/),
splits into ~120-token chunks with 30-token overlap,
generates embeddings with sentence-transformers, stores in SQLite.
Only re-embeds files with newer mtime than stored value.

Scopes:
    global   — $CLAUDE_MEMORY_HOME (default ~/.claude/memory)
    project  — <cwd-walked-up>/.claude/memory/  (opt-in: dir must exist)
    all      — both

Usage:
    memory-index.py                          # index global only
    memory-index.py --scope all              # global + project (if cwd has one)
    memory-index.py --scope project --cwd /path/to/project
"""

import argparse
import os
import re
import sqlite3
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
from common import (  # noqa: E402
    ANTARES_MODEL,
    CLAUDE_MEMORY_HOME,
    find_project_root,
)

import numpy as np  # noqa: E402

# Chunk parameters — tuned for paraphrase-multilingual-MiniLM-L12-v2
# (max_seq_length=128 tokens). Stay under 128 to avoid silent truncation.
# If you swap to a model with a larger window, bump these accordingly.
TARGET_TOKENS = 120
OVERLAP_TOKENS = 30


def get_scopes(scope_arg, cwd=None):
    """Return list of (name, memory_dir) tuples for the requested scope(s)."""
    scopes = []
    if scope_arg in ("global", "all"):
        scopes.append(("global", CLAUDE_MEMORY_HOME))
    if scope_arg in ("project", "all"):
        project_root = find_project_root(cwd)
        if project_root:
            scopes.append((
                f"project:{project_root}",
                os.path.join(project_root, ".claude", "memory"),
            ))
    return scopes


def detect_schema_version(conn):
    """Check if DB uses old (file-level) or new (chunk-level) schema."""
    tables = [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    ).fetchall()]
    if "memory_chunks" in tables:
        return 2
    if "memory_embeddings" in tables:
        return 1
    return 0


def init_db(conn):
    """Create v2 schema tables."""
    conn.execute("""CREATE TABLE IF NOT EXISTS memory_chunks (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        file_path     TEXT NOT NULL,
        chunk_index   INTEGER NOT NULL,
        content       TEXT NOT NULL,
        embedding     BLOB NOT NULL,
        last_modified REAL NOT NULL,
        file_type     TEXT,
        title         TEXT,
        UNIQUE(file_path, chunk_index)
    )""")
    conn.execute("""CREATE TABLE IF NOT EXISTS metadata (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    )""")
    conn.commit()


def migrate_v1_to_v2(conn):
    """Migrate from file-level to chunk-level schema."""
    print("Migrating schema v1 → v2 (file-level → chunked)...", flush=True)

    conn.execute("""CREATE TABLE memory_chunks (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        file_path     TEXT NOT NULL,
        chunk_index   INTEGER NOT NULL,
        content       TEXT NOT NULL,
        embedding     BLOB NOT NULL,
        last_modified REAL NOT NULL,
        file_type     TEXT,
        title         TEXT,
        UNIQUE(file_path, chunk_index)
    )""")

    conn.execute("""
        INSERT INTO memory_chunks (file_path, chunk_index, content, embedding,
                                   last_modified, file_type, title)
        SELECT file_path, 0, content, embedding, 0, file_type, title
        FROM memory_embeddings
    """)

    try:
        conn.execute("DROP TABLE IF EXISTS memory_fts")
    except sqlite3.OperationalError:
        pass
    conn.execute("DROP TABLE memory_embeddings")
    conn.commit()
    print("Migration complete. All files marked for re-chunking.", flush=True)


def get_md_files(memory_dir):
    """Find all .md files in memory dir, excluding MEMORY.md index."""
    files = []
    for root, _dirs, filenames in os.walk(memory_dir):
        for f in filenames:
            if f.endswith(".md") and f != "MEMORY.md":
                files.append(os.path.join(root, f))
    return files


def extract_content(filepath):
    """Read file, strip YAML frontmatter, return content + title."""
    with open(filepath, "r", encoding="utf-8") as f:
        text = f.read()
    if text.startswith("---"):
        end = text.find("---", 3)
        if end != -1:
            text = text[end + 3:].strip()
    title = os.path.basename(filepath)
    for line in text.split("\n"):
        if line.startswith("# "):
            title = line[2:].strip()
            break
    return text, title


def chunk_text(text, tokenizer, target_tokens=TARGET_TOKENS, overlap_tokens=OVERLAP_TOKENS):
    """Split text into overlapping chunks respecting paragraph boundaries."""
    token_ids = tokenizer.encode(text, add_special_tokens=False)
    total_tokens = len(token_ids)

    if total_tokens <= target_tokens:
        return [text]

    paragraphs = re.split(r"\n\n+", text)

    chunks = []
    current_paras = []
    current_count = 0

    for para in paragraphs:
        para_tokens = len(tokenizer.encode(para, add_special_tokens=False))

        if para_tokens > target_tokens:
            if current_paras:
                chunks.append("\n\n".join(current_paras))
                current_paras, current_count = _compute_overlap(
                    current_paras, tokenizer, overlap_tokens
                )

            lines = para.split("\n")
            for line in lines:
                line_tokens = len(tokenizer.encode(line, add_special_tokens=False))
                if current_count + line_tokens > target_tokens and current_paras:
                    chunks.append("\n\n".join(current_paras))
                    current_paras, current_count = _compute_overlap(
                        current_paras, tokenizer, overlap_tokens
                    )
                current_paras.append(line)
                current_count += line_tokens
            continue

        if current_count + para_tokens > target_tokens and current_paras:
            chunks.append("\n\n".join(current_paras))
            current_paras, current_count = _compute_overlap(
                current_paras, tokenizer, overlap_tokens
            )

        current_paras.append(para)
        current_count += para_tokens

    if current_paras:
        chunks.append("\n\n".join(current_paras))

    return chunks


def _compute_overlap(paragraphs, tokenizer, overlap_tokens):
    """Keep trailing paragraphs up to overlap_tokens for the next chunk."""
    overlap_paras = []
    token_count = 0
    for para in reversed(paragraphs):
        para_tokens = len(tokenizer.encode(para, add_special_tokens=False))
        if token_count + para_tokens > overlap_tokens:
            break
        overlap_paras.insert(0, para)
        token_count += para_tokens
    return overlap_paras, token_count


def needs_update(conn, filepath, mtime):
    """Check if file needs re-chunking."""
    row = conn.execute(
        "SELECT last_modified FROM memory_chunks WHERE file_path = ? LIMIT 1",
        (filepath,),
    ).fetchone()
    return row is None or row[0] < mtime


def index_scope(model, scope_name, memory_dir):
    """Index a single scope's memory directory."""
    if not os.path.isdir(memory_dir):
        # Project scope with no dir → no-op (caller already filtered, but be safe).
        return

    db_path = os.path.join(memory_dir, ".memory-index.db")
    conn = sqlite3.connect(db_path)

    version = detect_schema_version(conn)
    if version == 0:
        init_db(conn)
    elif version == 1:
        migrate_v1_to_v2(conn)

    tokenizer = model.tokenizer

    files = get_md_files(memory_dir)
    updated = 0

    for filepath in files:
        mtime = os.path.getmtime(filepath)
        if not needs_update(conn, filepath, mtime):
            continue

        content, title = extract_content(filepath)
        if not content.strip():
            continue

        file_type = "journal" if "/journal/" in filepath else "memory"
        chunks = chunk_text(content, tokenizer)

        conn.execute("DELETE FROM memory_chunks WHERE file_path = ?", (filepath,))

        for i, chunk_content in enumerate(chunks):
            embedding = model.encode(chunk_content, normalize_embeddings=True)
            embedding_blob = embedding.astype(np.float32).tobytes()
            conn.execute(
                """INSERT INTO memory_chunks
                (file_path, chunk_index, content, embedding, last_modified, file_type, title)
                VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (filepath, i, chunk_content, embedding_blob, mtime, file_type, title),
            )
        updated += 1

    existing = set(files)
    db_files = set(
        r[0] for r in conn.execute("SELECT DISTINCT file_path FROM memory_chunks")
    )
    for db_file in db_files:
        if db_file not in existing:
            conn.execute("DELETE FROM memory_chunks WHERE file_path = ?", (db_file,))
            updated += 1

    # Ensure FTS table exists and is in sync. Created here (not inside the
    # search path) so the daemon can open the DB read-only without ever
    # needing schema-write access.
    fts_exists = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='memory_fts'"
    ).fetchone()
    if not fts_exists:
        conn.execute(
            "CREATE VIRTUAL TABLE memory_fts USING fts5("
            "title, content, content=memory_chunks, content_rowid=id"
            ")"
        )
        conn.execute(
            "INSERT INTO memory_fts(rowid, title, content) "
            "SELECT id, title, content FROM memory_chunks"
        )
    else:
        conn.execute("INSERT INTO memory_fts(memory_fts) VALUES('rebuild')")

    conn.execute(
        "INSERT OR REPLACE INTO metadata VALUES ('last_index_time', ?)",
        (str(time.time()),),
    )
    conn.execute(
        "INSERT OR REPLACE INTO metadata VALUES ('model_name', ?)", (ANTARES_MODEL,)
    )
    conn.execute(
        "INSERT OR REPLACE INTO metadata VALUES ('embedding_dim', '384')"
    )
    conn.execute(
        "INSERT OR REPLACE INTO metadata VALUES ('schema_version', '2')"
    )
    conn.commit()
    conn.close()

    if updated > 0:
        print(f"[{scope_name}] Indexed {updated} file(s).", flush=True)


def main():
    parser = argparse.ArgumentParser(description="Index memory embeddings (chunked)")
    parser.add_argument(
        "-s",
        "--scope",
        default="global",
        choices=["global", "project", "all"],
        help="Scope to index (default: global). Project scope reads <cwd>/.claude/memory/.",
    )
    parser.add_argument(
        "--cwd",
        default=os.getcwd(),
        help="Working directory used to resolve project scope (default: $PWD).",
    )
    args = parser.parse_args()

    try:
        from sentence_transformers import SentenceTransformer
    except ImportError:
        print(
            "Error: sentence-transformers not installed.\n"
            "Run /antares-memory:install to set up the venv.",
            file=sys.stderr,
        )
        sys.exit(1)

    scopes = get_scopes(args.scope, args.cwd)

    if not scopes:
        if args.scope == "project":
            print(f"No project memory at cwd={args.cwd}", file=sys.stderr)
            sys.exit(0)
        print(f"No memory directories found for scope '{args.scope}'", file=sys.stderr)
        sys.exit(1)

    # Ensure global dir exists before opening DB (idempotent — install creates it,
    # but a manual reindex on a fresh box shouldn't crash).
    for _name, memory_dir in scopes:
        os.makedirs(memory_dir, exist_ok=True)

    model = SentenceTransformer(ANTARES_MODEL)
    for scope_name, memory_dir in scopes:
        index_scope(model, scope_name, memory_dir)


if __name__ == "__main__":
    main()
