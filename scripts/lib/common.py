"""scripts/lib/common.py — shared env resolution for antares-memory Python scripts.

Import from sibling scripts:

    import sys, os
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
    from common import (
        CLAUDE_MEMORY_HOME, ANTARES_MODEL, ANTARES_STATE,
        global_db_path, find_project_root,
    )
"""

import os

HOME = os.path.expanduser("~")

CLAUDE_MEMORY_HOME = os.environ.get(
    "CLAUDE_MEMORY_HOME", os.path.join(HOME, ".claude", "memory")
)
ANTARES_VENV = os.environ.get(
    "ANTARES_VENV", os.path.join(HOME, ".local", "share", "antares-memory", "venv")
)
ANTARES_STATE = os.environ.get(
    "ANTARES_STATE", os.path.join(HOME, ".local", "state", "antares-memory")
)
ANTARES_MODEL = os.environ.get(
    "ANTARES_MODEL", "paraphrase-multilingual-MiniLM-L12-v2"
)

CLAUDE_HOME = os.path.join(HOME, ".claude")


def global_db_path():
    """Path to the global memory SQLite index."""
    return os.path.join(CLAUDE_MEMORY_HOME, ".memory-index.db")


def project_db_path(project_root):
    """Path to a project-scoped memory SQLite index."""
    return os.path.join(project_root, ".claude", "memory", ".memory-index.db")


def find_project_root(cwd):
    """Walk up from cwd looking for a directory containing .claude/memory/.

    Returns the project root path (parent of .claude/), or None if no project
    context. Excludes paths under ~/.claude/ to avoid confusion with the global
    memory location (which lives under the user's home, not under any project).
    """
    if not cwd:
        return None
    current = os.path.abspath(cwd)
    if current == CLAUDE_HOME or current.startswith(CLAUDE_HOME + os.sep):
        return None
    while current and current != "/" and current != HOME:
        candidate = os.path.join(current, ".claude", "memory")
        if os.path.isdir(candidate):
            return current
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    return None
