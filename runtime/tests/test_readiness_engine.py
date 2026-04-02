#!/usr/bin/env python3
"""Tests for the HYDRA readiness engine scheduler daemon."""
import json
import os
import sqlite3
import sys
import tempfile
import unittest

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
    import uuid
    return uuid.uuid4().hex


class TestSatisfyDeps(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_satisfy_deps_marks_satisfied(self):
        """Job A completed, B depends on A. After satisfy_deps, dep is satisfied and B is ready."""
        from readiness_engine import satisfy_deps

        a_id = _id()
        b_id = _id()
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'completed', 'Job A')",
            (a_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'pending', 'Job B')",
            (b_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_job_deps (job_id, depends_on_id, status) VALUES (?, ?, 'pending')",
            (b_id, a_id),
        )
        self.conn.commit()

        satisfy_deps(self.conn)

        dep = self.conn.execute(
            "SELECT status FROM rt_job_deps WHERE job_id = ? AND depends_on_id = ?",
            (b_id, a_id),
        ).fetchone()
        self.assertEqual(dep["status"], "satisfied")

        job_b = self.conn.execute(
            "SELECT status FROM rt_jobs WHERE id = ?", (b_id,)
        ).fetchone()
        self.assertEqual(job_b["status"], "ready")

    def test_satisfy_deps_partial(self):
        """Job depends on A (completed) and C (pending). Job stays pending."""
        from readiness_engine import satisfy_deps

        a_id = _id()
        c_id = _id()
        b_id = _id()
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'completed', 'Job A')",
            (a_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'pending', 'Job C')",
            (c_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'pending', 'Job B')",
            (b_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_job_deps (job_id, depends_on_id, status) VALUES (?, ?, 'pending')",
            (b_id, a_id),
        )
        self.conn.execute(
            "INSERT INTO rt_job_deps (job_id, depends_on_id, status) VALUES (?, ?, 'pending')",
            (b_id, c_id),
        )
        self.conn.commit()

        satisfy_deps(self.conn)

        # A dep should be satisfied
        dep_a = self.conn.execute(
            "SELECT status FROM rt_job_deps WHERE job_id = ? AND depends_on_id = ?",
            (b_id, a_id),
        ).fetchone()
        self.assertEqual(dep_a["status"], "satisfied")

        # C dep still pending
        dep_c = self.conn.execute(
            "SELECT status FROM rt_job_deps WHERE job_id = ? AND depends_on_id = ?",
            (b_id, c_id),
        ).fetchone()
        self.assertEqual(dep_c["status"], "pending")

        # Job B stays pending (not all deps met)
        job_b = self.conn.execute(
            "SELECT status FROM rt_jobs WHERE id = ?", (b_id,)
        ).fetchone()
        self.assertEqual(job_b["status"], "pending")


class TestScheduleReadyJobs(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_schedule_ready_jobs_creates_run(self):
        """Ready job with no runs gets a pending run."""
        from readiness_engine import schedule_ready_jobs

        j_id = _id()
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'ready', 'Ready Job')",
            (j_id,),
        )
        self.conn.commit()

        schedule_ready_jobs(self.conn)

        runs = self.conn.execute(
            "SELECT * FROM rt_runs WHERE job_id = ?", (j_id,)
        ).fetchall()
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["status"], "pending")

    def test_schedule_ready_jobs_no_duplicate(self):
        """Ready job with existing pending run does not get another."""
        from readiness_engine import schedule_ready_jobs

        j_id = _id()
        r_id = _id()
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'ready', 'Ready Job')",
            (j_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_runs (id, job_id, status) VALUES (?, ?, 'pending')",
            (r_id, j_id),
        )
        self.conn.commit()

        schedule_ready_jobs(self.conn)

        runs = self.conn.execute(
            "SELECT * FROM rt_runs WHERE job_id = ?", (j_id,)
        ).fetchall()
        self.assertEqual(len(runs), 1)

    def test_schedule_ready_jobs_idempotent(self):
        """Calling schedule_ready_jobs twice still produces only one run."""
        from readiness_engine import schedule_ready_jobs

        j_id = _id()
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'ready', 'Ready Job')",
            (j_id,),
        )
        self.conn.commit()

        schedule_ready_jobs(self.conn)
        schedule_ready_jobs(self.conn)

        runs = self.conn.execute(
            "SELECT * FROM rt_runs WHERE job_id = ?", (j_id,)
        ).fetchall()
        self.assertEqual(len(runs), 1)


class TestDetectStaleClaims(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_detect_stale_claims_marks_failed(self):
        """Expired claim: claim deleted, run failed, job back to ready (retries remain)."""
        from readiness_engine import detect_stale_claims

        j_id = _id()
        r_id = _id()
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title, retry_count, max_retries) "
            "VALUES (?, 'milo', 'running', 'Stale Job', 0, 3)",
            (j_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_runs (id, job_id, status) VALUES (?, ?, 'running')",
            (r_id, j_id),
        )
        self.conn.execute(
            "INSERT INTO rt_run_claims (run_id, worker_id, lease_ttl_sec) VALUES (?, 'worker-1', 300)",
            (r_id,),
        )
        # Expire the heartbeat
        self.conn.execute(
            "UPDATE rt_run_claims SET last_heartbeat = datetime('now', '-10 minutes')"
        )
        self.conn.commit()

        detect_stale_claims(self.conn)

        # Claim should be deleted
        claim = self.conn.execute(
            "SELECT * FROM rt_run_claims WHERE run_id = ?", (r_id,)
        ).fetchone()
        self.assertIsNone(claim)

        # Run should be failed
        run = self.conn.execute(
            "SELECT status, error FROM rt_runs WHERE id = ?", (r_id,)
        ).fetchone()
        self.assertEqual(run["status"], "failed")
        self.assertEqual(run["error"], "lease_expired")

        # Job should be back to ready with incremented retry_count
        job = self.conn.execute(
            "SELECT status, retry_count FROM rt_jobs WHERE id = ?", (j_id,)
        ).fetchone()
        self.assertEqual(job["status"], "ready")
        self.assertEqual(job["retry_count"], 1)

    def test_detect_stale_claims_exhausts_retries(self):
        """Expired claim with max retries exhausted: job fails."""
        from readiness_engine import detect_stale_claims

        j_id = _id()
        r_id = _id()
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title, retry_count, max_retries) "
            "VALUES (?, 'milo', 'running', 'Exhausted Job', 3, 3)",
            (j_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_runs (id, job_id, status) VALUES (?, ?, 'running')",
            (r_id, j_id),
        )
        self.conn.execute(
            "INSERT INTO rt_run_claims (run_id, worker_id, lease_ttl_sec) VALUES (?, 'worker-1', 300)",
            (r_id,),
        )
        self.conn.execute(
            "UPDATE rt_run_claims SET last_heartbeat = datetime('now', '-10 minutes')"
        )
        self.conn.commit()

        detect_stale_claims(self.conn)

        job = self.conn.execute(
            "SELECT status FROM rt_jobs WHERE id = ?", (j_id,)
        ).fetchone()
        self.assertEqual(job["status"], "failed")

        # Should have a job.failed event
        event = self.conn.execute(
            "SELECT * FROM rt_events WHERE job_id = ? AND event_type = 'job.failed'",
            (j_id,),
        ).fetchone()
        self.assertIsNotNone(event)


class TestNoDepsJob(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_no_deps_job_starts_as_ready(self):
        """A job with status='ready' and no deps gets scheduled."""
        from readiness_engine import schedule_ready_jobs

        j_id = _id()
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'ready', 'No Deps Job')",
            (j_id,),
        )
        self.conn.commit()

        schedule_ready_jobs(self.conn)

        runs = self.conn.execute(
            "SELECT * FROM rt_runs WHERE job_id = ?", (j_id,)
        ).fetchall()
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["status"], "pending")


class TestResolveChildResults(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_resolve_child_results_marks_dep_resolved(self):
        """Completed child job resolves rt_run_deps with wait_type='child_result'."""
        from readiness_engine import resolve_child_results

        parent_job_id = _id()
        child_job_id = _id()
        parent_run_id = _id()
        dep_id = _id()

        # Parent job and run in waiting state
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'waiting', 'Parent Job')",
            (parent_job_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_runs (id, job_id, status) VALUES (?, ?, 'waiting')",
            (parent_run_id, parent_job_id),
        )

        # Child job completed with a result
        child_result = json.dumps({"answer": 42})
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title, result, parent_job_id) "
            "VALUES (?, 'forge', 'completed', 'Child Job', ?, ?)",
            (child_job_id, child_result, parent_job_id),
        )

        # rt_run_deps with target_id pointing to child JOB
        self.conn.execute(
            "INSERT INTO rt_run_deps (id, run_id, wait_type, target_id, status) "
            "VALUES (?, ?, 'child_result', ?, 'pending')",
            (dep_id, parent_run_id, child_job_id),
        )
        self.conn.commit()

        resolve_child_results(self.conn)

        dep = self.conn.execute(
            "SELECT status, result FROM rt_run_deps WHERE id = ?", (dep_id,)
        ).fetchone()
        self.assertEqual(dep["status"], "resolved")
        self.assertEqual(dep["result"], child_result)


if __name__ == "__main__":
    unittest.main()
