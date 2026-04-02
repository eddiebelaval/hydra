#!/usr/bin/env python3
"""test_integration_phase1.py -- End-to-end Phase 1 integration tests.

Exercises readiness_engine, claim_and_execute, and rt_db working together
through the full job lifecycle using in-memory (temp file) SQLite.
"""
import json
import os
import sqlite3
import sys
import tempfile
import unittest
import uuid

INIT_PATH = os.path.expanduser("~/.hydra/init-db.sql")
MIGRATION_PATH = os.path.expanduser("~/.hydra/migrations/003-runtime-engine.sql")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from rt_db import connect, generate_id
from readiness_engine import satisfy_deps, schedule_ready_jobs, detect_stale_claims, resolve_child_results, resume_waiting_runs
from claim_and_execute import claim, complete_run, fail_run


def create_test_db():
    db_path = tempfile.mktemp(suffix='.db')
    conn = sqlite3.connect(db_path)
    conn.executescript(open(INIT_PATH).read())
    conn.executescript(open(MIGRATION_PATH).read())
    conn.row_factory = sqlite3.Row
    return db_path, conn


def _id():
    return uuid.uuid4().hex


def _open_conn(db_path):
    """Open a second WAL-mode connection to the test DB."""
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode = WAL;")
    conn.execute("PRAGMA busy_timeout = 5000;")
    conn.execute("PRAGMA foreign_keys = ON;")
    conn.row_factory = sqlite3.Row
    return conn


def _insert_agent(conn, agent_id):
    """Insert a minimal agent row to satisfy FK on rt_jobs (uses OR IGNORE)."""
    conn.execute(
        "INSERT OR IGNORE INTO agents (id, name, role, session_key, model) "
        "VALUES (?, ?, 'dev', 'test-session', 'anthropic/claude-sonnet-4')",
        (agent_id, agent_id.capitalize()),
    )
    conn.commit()


class TestFullJobLifecycle(unittest.TestCase):
    """Test 1: Happy path from ready job through schedule, claim, and complete."""

    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        if os.path.exists(self.db_path):
            os.unlink(self.db_path)

    def test_full_job_lifecycle(self):
        # 1. Insert a ready job for agent 'forge'
        _insert_agent(self.conn, "forge")
        job_id = _id()
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title, payload) "
            "VALUES (?, 'forge', 'ready', 'Integration Test Job', '{}')",
            (job_id,),
        )
        self.conn.commit()

        # 2. schedule_ready_jobs should create a pending run
        schedule_ready_jobs(self.conn)

        # 3. Assert: run exists with status='pending'
        run = self.conn.execute(
            "SELECT id, status FROM rt_runs WHERE job_id = ?", (job_id,)
        ).fetchone()
        self.assertIsNotNone(run, "Expected a pending run to be created")
        self.assertEqual(run["status"], "pending")
        run_id = run["id"]

        # 4. Open a second connection, call claim(conn2, 'forge', 'forge-12345')
        conn2 = _open_conn(self.db_path)
        result = claim(conn2, "forge", "forge-12345")

        # 5. Assert: claim returned non-None, run is 'running', job is 'running'
        self.assertIsNotNone(result, "Expected claim to succeed")
        self.assertEqual(result["run_id"], run_id)
        self.assertEqual(result["job_id"], job_id)

        run_after = conn2.execute(
            "SELECT status FROM rt_runs WHERE id = ?", (run_id,)
        ).fetchone()
        self.assertEqual(run_after["status"], "running")

        job_after = conn2.execute(
            "SELECT status FROM rt_jobs WHERE id = ?", (job_id,)
        ).fetchone()
        self.assertEqual(job_after["status"], "running")

        # 6. Assert: rt_run_claims row exists with worker_id='forge-12345'
        claim_row = conn2.execute(
            "SELECT worker_id FROM rt_run_claims WHERE run_id = ?", (run_id,)
        ).fetchone()
        self.assertIsNotNone(claim_row, "Expected rt_run_claims row to exist")
        self.assertEqual(claim_row["worker_id"], "forge-12345")

        # 7. Call complete_run
        complete_run(conn2, run_id, job_id, '{"result": "done"}')

        # 8. Assert: run='completed', job='completed', rt_events has entry
        run_final = conn2.execute(
            "SELECT status FROM rt_runs WHERE id = ?", (run_id,)
        ).fetchone()
        self.assertEqual(run_final["status"], "completed")

        job_final = conn2.execute(
            "SELECT status FROM rt_jobs WHERE id = ?", (job_id,)
        ).fetchone()
        self.assertEqual(job_final["status"], "completed")

        event = conn2.execute(
            "SELECT event_type FROM rt_events WHERE run_id = ? AND event_type = 'run.completed'",
            (run_id,),
        ).fetchone()
        self.assertIsNotNone(event, "Expected run.completed event in rt_events")

        conn2.close()


class TestDependencyChain(unittest.TestCase):
    """Test 2: Job B stays pending until Job A completes, then becomes ready."""

    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        if os.path.exists(self.db_path):
            os.unlink(self.db_path)

    def test_dependency_chain(self):
        # Insert agents
        _insert_agent(self.conn, "forge")
        _insert_agent(self.conn, "scout")

        # 1. Insert job A for 'forge' with status='ready'
        job_a_id = _id()
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title, payload) "
            "VALUES (?, 'forge', 'ready', 'Job A', '{}')",
            (job_a_id,),
        )

        # 2. Insert job B for 'scout' with status='pending'
        job_b_id = _id()
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title, payload) "
            "VALUES (?, 'scout', 'pending', 'Job B', '{}')",
            (job_b_id,),
        )

        # 3. Insert rt_job_deps: B depends on A
        self.conn.execute(
            "INSERT INTO rt_job_deps (job_id, depends_on_id, status) "
            "VALUES (?, ?, 'pending')",
            (job_b_id, job_a_id),
        )
        self.conn.commit()

        # 4. satisfy_deps: A is not completed yet, B stays pending
        satisfy_deps(self.conn)

        # 5. Assert: B is still 'pending'
        job_b = self.conn.execute(
            "SELECT status FROM rt_jobs WHERE id = ?", (job_b_id,)
        ).fetchone()
        self.assertEqual(job_b["status"], "pending", "B should still be pending (A not completed)")

        # 6. Update A to 'completed' directly
        self.conn.execute(
            "UPDATE rt_jobs SET status = 'completed' WHERE id = ?", (job_a_id,)
        )
        self.conn.commit()

        # 7. satisfy_deps: now A is completed, dep should be satisfied, B becomes 'ready'
        satisfy_deps(self.conn)

        # 8. Assert: dep status='satisfied', B status='ready'
        dep = self.conn.execute(
            "SELECT status FROM rt_job_deps WHERE job_id = ? AND depends_on_id = ?",
            (job_b_id, job_a_id),
        ).fetchone()
        self.assertIsNotNone(dep, "Expected dep row to exist")
        self.assertEqual(dep["status"], "satisfied")

        job_b_after = self.conn.execute(
            "SELECT status FROM rt_jobs WHERE id = ?", (job_b_id,)
        ).fetchone()
        self.assertEqual(job_b_after["status"], "ready")

        # 9. schedule_ready_jobs should create a pending run for B
        schedule_ready_jobs(self.conn)

        # 10. Assert: run exists for B
        run_b = self.conn.execute(
            "SELECT id, status FROM rt_runs WHERE job_id = ?", (job_b_id,)
        ).fetchone()
        self.assertIsNotNone(run_b, "Expected a pending run for Job B")
        self.assertEqual(run_b["status"], "pending")


class TestRetryOnFailure(unittest.TestCase):
    """Test 3: Job retries after failure, second run is created."""

    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        if os.path.exists(self.db_path):
            os.unlink(self.db_path)

    def test_retry_on_failure(self):
        # 1. Insert a ready job for 'forge' with max_retries=3
        _insert_agent(self.conn, "forge")
        job_id = _id()
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title, payload, max_retries, retry_count) "
            "VALUES (?, 'forge', 'ready', 'Retry Test Job', '{}', 3, 0)",
            (job_id,),
        )
        self.conn.commit()

        # 2. Schedule and claim the run
        schedule_ready_jobs(self.conn)

        run = self.conn.execute(
            "SELECT id FROM rt_runs WHERE job_id = ?", (job_id,)
        ).fetchone()
        self.assertIsNotNone(run, "Expected a pending run after scheduling")
        run_id = run["id"]

        result = claim(self.conn, "forge", "forge-retry-worker")
        self.assertIsNotNone(result, "Expected claim to succeed")

        # 3. Call fail_run with an error
        fail_run(self.conn, run_id, job_id, "simulated failure")

        # 4. Assert: run='failed', job retry_count=1
        run_after = self.conn.execute(
            "SELECT status FROM rt_runs WHERE id = ?", (run_id,)
        ).fetchone()
        self.assertEqual(run_after["status"], "failed")

        job_after = self.conn.execute(
            "SELECT retry_count FROM rt_jobs WHERE id = ?", (job_id,)
        ).fetchone()
        self.assertEqual(job_after["retry_count"], 1)

        # 5. detect_stale_claims: should be a no-op (claim already cleaned up by fail_run)
        detect_stale_claims(self.conn)

        claim_row = self.conn.execute(
            "SELECT run_id FROM rt_run_claims WHERE run_id = ?", (run_id,)
        ).fetchone()
        self.assertIsNone(claim_row, "Claim should already be removed by fail_run")

        # 6. Manually set job status back to 'ready' (simulating readiness engine retry logic)
        self.conn.execute(
            "UPDATE rt_jobs SET status = 'ready' WHERE id = ?", (job_id,)
        )
        self.conn.commit()

        # 7. schedule_ready_jobs: should create a new pending run
        schedule_ready_jobs(self.conn)

        # 8. Assert: second run exists
        runs = self.conn.execute(
            "SELECT id, status FROM rt_runs WHERE job_id = ? ORDER BY created_at",
            (job_id,),
        ).fetchall()
        self.assertEqual(len(runs), 2, "Expected exactly 2 runs: one failed, one pending")

        second_run = runs[1]
        self.assertEqual(second_run["status"], "pending", "Second run should be pending")
        self.assertNotEqual(second_run["id"], run_id, "Second run should have a new ID")


if __name__ == "__main__":
    unittest.main(verbosity=2)
