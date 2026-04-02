#!/usr/bin/env python3
"""rt_db.py -- Shared database helpers for the HYDRA runtime engine.

Provides connection factory with WAL mode, ID generation, constants,
and transaction helpers. All runtime modules import from here.
"""
import os
import sqlite3
import uuid

HYDRA_DB = os.path.expanduser("~/.hydra/hydra.db")

# Valid status values
JOB_STATUSES = frozenset({'pending', 'ready', 'running', 'waiting', 'completed', 'failed'})
RUN_STATUSES = frozenset({'pending', 'running', 'waiting', 'completed', 'failed'})
DEP_STATUSES = frozenset({'pending', 'satisfied'})
WAIT_TYPES = frozenset({'child_result', 'human_input', 'external'})
RUN_DEP_STATUSES = frozenset({'pending', 'resolved'})


def connect(db_path=None):
    """Open a connection with WAL mode, busy timeout, and foreign keys."""
    path = db_path or HYDRA_DB
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode = WAL;")
    conn.execute("PRAGMA busy_timeout = 5000;")
    conn.execute("PRAGMA foreign_keys = ON;")
    conn.row_factory = sqlite3.Row
    return conn


def generate_id():
    """Generate a 32-character lowercase hex ID."""
    return uuid.uuid4().hex
