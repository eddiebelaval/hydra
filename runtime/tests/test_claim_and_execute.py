#!/usr/bin/env python3
"""Tests for claim_and_execute -- atomic claim and single-shot execution."""
import json
import os
import sqlite3
import sys
import tempfile
import unittest
import uuid

INIT_PATH = os.path.expanduser("~/.hydra/init-db.sql")
MIGRATION_PATH = os.path.expanduser("~/.hydra/migrations/003-runtime-engine.sql")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


def create_test_db():
    db_path = tempfile.mktemp(suffix=".db")
    conn = sqlite3.connect(db_path)
    conn.executescript(open(INIT_PATH).read())
    conn.executescript(open(MIGRATION_PATH).read())
    conn.row_factory = sqlite3.Row
    return db_path, conn


def _id():
    return uuid.uuid4().hex


def _insert_agent(conn, agent_id="forge"):
    """Insert a minimal agent row to satisfy the FK on rt_jobs."""
    conn.execute(
        "INSERT OR IGNORE INTO agents (id, name, role, session_key, model) "
        "VALUES (?, ?, 'dev', 'test-session', 'anthropic/claude-sonnet-4')",
        (agent_id, agent_id.capitalize()),
    )
    conn.commit()


def _make_ready_job_and_run(conn, agent_id="forge"):
    """Create a ready job and a pending run, return (job_id, run_id)."""
    _insert_agent(conn, agent_id)
    job_id = _id()
    run_id = _id()
    conn.execute(
        "INSERT INTO rt_jobs (id, agent_id, status, title, payload) "
        "VALUES (?, ?, 'ready', 'Test Job', '{}')",
        (job_id, agent_id),
    )
    conn.execute(
        "INSERT INTO rt_runs (id, job_id, status) VALUES (?, ?, 'pending')",
        (run_id, job_id),
    )
    conn.commit()
    return job_id, run_id


class TestClaimSucceeds(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_claim_succeeds(self):
        """Claim on a pending run sets the claim, run status=running, job status=running."""
        from claim_and_execute import claim

        job_id, run_id = _make_ready_job_and_run(self.conn, "forge")

        result = claim(self.conn, "forge", "forge-123")

        self.assertIsNotNone(result)
        self.assertEqual(result["run_id"], run_id)
        self.assertEqual(result["job_id"], job_id)

        # rt_run_claims row exists
        claim_row = self.conn.execute(
            "SELECT worker_id FROM rt_run_claims WHERE run_id = ?", (run_id,)
        ).fetchone()
        self.assertIsNotNone(claim_row)
        self.assertEqual(claim_row["worker_id"], "forge-123")

        # Run status is running
        run = self.conn.execute(
            "SELECT status FROM rt_runs WHERE id = ?", (run_id,)
        ).fetchone()
        self.assertEqual(run["status"], "running")

        # Job status is running
        job = self.conn.execute(
            "SELECT status FROM rt_jobs WHERE id = ?", (job_id,)
        ).fetchone()
        self.assertEqual(job["status"], "running")


class TestClaimNoWork(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_claim_no_work(self):
        """Empty DB (no pending runs) returns None."""
        from claim_and_execute import claim

        result = claim(self.conn, "forge", "forge-123")
        self.assertIsNone(result)


class TestClaimRaceSecondLoses(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_claim_race_second_loses(self):
        """Two concurrent claims on the same run: first wins, second returns None."""
        from claim_and_execute import claim

        job_id, run_id = _make_ready_job_and_run(self.conn, "forge")

        # Worker A claims on the primary connection
        result_a = claim(self.conn, "forge", "worker-A")
        self.assertIsNotNone(result_a)

        # Open a second connection to the same DB
        conn2 = sqlite3.connect(self.db_path)
        conn2.execute("PRAGMA journal_mode = WAL;")
        conn2.execute("PRAGMA busy_timeout = 5000;")
        conn2.execute("PRAGMA foreign_keys = ON;")
        conn2.row_factory = sqlite3.Row

        # Worker B tries to claim the same run -- PK conflict on rt_run_claims
        result_b = claim(conn2, "forge", "worker-B")
        self.assertIsNone(result_b)

        conn2.close()

        # Confirm worker A still owns the claim
        claim_row = self.conn.execute(
            "SELECT worker_id FROM rt_run_claims WHERE run_id = ?", (run_id,)
        ).fetchone()
        self.assertEqual(claim_row["worker_id"], "worker-A")


class TestCompleteRunMarksCompleted(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_complete_run_marks_completed(self):
        """complete_run sets run and job to completed and emits run.completed event."""
        from claim_and_execute import claim, complete_run

        job_id, run_id = _make_ready_job_and_run(self.conn, "forge")
        run_info = claim(self.conn, "forge", "forge-123")
        self.assertIsNotNone(run_info)

        result_json = json.dumps({"output": "done"})
        complete_run(self.conn, run_id, job_id, result_json)

        run = self.conn.execute(
            "SELECT status, result FROM rt_runs WHERE id = ?", (run_id,)
        ).fetchone()
        self.assertEqual(run["status"], "completed")
        self.assertEqual(run["result"], result_json)

        job = self.conn.execute(
            "SELECT status FROM rt_jobs WHERE id = ?", (job_id,)
        ).fetchone()
        self.assertEqual(job["status"], "completed")

        event = self.conn.execute(
            "SELECT event_type FROM rt_events WHERE run_id = ? AND event_type = 'run.completed'",
            (run_id,),
        ).fetchone()
        self.assertIsNotNone(event)


class TestFailRunIncrementsRetry(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_fail_run_increments_retry(self):
        """fail_run sets run to failed, increments job retry_count, emits run.failed event."""
        from claim_and_execute import claim, fail_run

        job_id, run_id = _make_ready_job_and_run(self.conn, "forge")
        run_info = claim(self.conn, "forge", "forge-123")
        self.assertIsNotNone(run_info)

        # Capture retry_count before fail
        job_before = self.conn.execute(
            "SELECT retry_count FROM rt_jobs WHERE id = ?", (job_id,)
        ).fetchone()
        retry_before = job_before["retry_count"]

        fail_run(self.conn, run_id, job_id, "subprocess exited with code 1")

        run = self.conn.execute(
            "SELECT status, error FROM rt_runs WHERE id = ?", (run_id,)
        ).fetchone()
        self.assertEqual(run["status"], "failed")
        self.assertEqual(run["error"], "subprocess exited with code 1")

        job = self.conn.execute(
            "SELECT retry_count FROM rt_jobs WHERE id = ?", (job_id,)
        ).fetchone()
        self.assertEqual(job["retry_count"], retry_before + 1)

        event = self.conn.execute(
            "SELECT event_type FROM rt_events WHERE run_id = ? AND event_type = 'run.failed'",
            (run_id,),
        ).fetchone()
        self.assertIsNotNone(event)


if __name__ == "__main__":
    unittest.main()
