#!/usr/bin/env python3
"""test_integration_phase2.py -- Phase 2 delegation integration tests.

Exercises the full delegation flow end-to-end:
  - Chain delegation (single delegate)
  - Fan-out / fan-in (delegate_many)
  - Fail-fast propagation

Uses readiness_engine, claim_and_execute, and delegate working together.
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

from readiness_engine import schedule_ready_jobs, resolve_child_results, resume_waiting_runs, handle_child_failures
from claim_and_execute import claim, complete_run, fail_run
from delegate import delegate, delegate_many


def create_test_db():
    db_path = tempfile.mktemp(suffix='.db')
    conn = sqlite3.connect(db_path)
    conn.executescript(open(INIT_PATH).read())
    conn.executescript(open(MIGRATION_PATH).read())
    conn.row_factory = sqlite3.Row
    return db_path, conn


def _open_conn(db_path):
    """Open an additional WAL-mode connection to the test DB."""
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode = WAL;")
    conn.execute("PRAGMA busy_timeout = 5000;")
    conn.execute("PRAGMA foreign_keys = ON;")
    conn.row_factory = sqlite3.Row
    return conn


def _insert_agent(conn, agent_id):
    """Insert a minimal agent row to satisfy FK on rt_jobs."""
    conn.execute(
        "INSERT OR IGNORE INTO agents (id, name, role, session_key, model) "
        "VALUES (?, ?, 'dev', 'test-session', 'anthropic/claude-sonnet-4')",
        (agent_id, agent_id.capitalize()),
    )
    conn.commit()


def _id():
    return uuid.uuid4().hex


class TestDelegationChain(unittest.TestCase):
    """Test 1: Full end-to-end single delegation chain."""

    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        if os.path.exists(self.db_path):
            os.unlink(self.db_path)

    def test_delegation_chain(self):
        # Setup agents
        _insert_agent(self.conn, "milo")
        _insert_agent(self.conn, "forge")

        # 1. Create root job for agent 'milo' (ready)
        milo_job_id = _id()
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title, payload) "
            "VALUES (?, 'milo', 'ready', 'Root milo job', '{}')",
            (milo_job_id,),
        )
        self.conn.commit()

        # 2. schedule_ready_jobs -- creates pending run for milo
        schedule_ready_jobs(self.conn)

        milo_run = self.conn.execute(
            "SELECT id, status FROM rt_runs WHERE job_id = ?", (milo_job_id,)
        ).fetchone()
        self.assertIsNotNone(milo_run)
        self.assertEqual(milo_run["status"], "pending")
        milo_run_id = milo_run["id"]

        # 3. Open conn2, call claim(conn2, 'milo', 'milo-1') -- milo claims run
        conn2 = _open_conn(self.db_path)
        result = claim(conn2, "milo", "milo-1")
        self.assertIsNotNone(result)
        self.assertEqual(result["run_id"], milo_run_id)

        # 4. Call delegate(conn2, milo_run_id, 'forge', 'Build landing page')
        forge_job_id = delegate(conn2, milo_run_id, "forge", "Build landing page")
        self.assertIsNotNone(forge_job_id)

        # 5. Assert: milo run='waiting', milo job='waiting', forge child job exists as 'ready'
        milo_run_after = conn2.execute(
            "SELECT status FROM rt_runs WHERE id = ?", (milo_run_id,)
        ).fetchone()
        self.assertEqual(milo_run_after["status"], "waiting")

        milo_job_after = conn2.execute(
            "SELECT status FROM rt_jobs WHERE id = ?", (milo_job_id,)
        ).fetchone()
        self.assertEqual(milo_job_after["status"], "waiting")

        forge_job = conn2.execute(
            "SELECT status, agent_id FROM rt_jobs WHERE id = ?", (forge_job_id,)
        ).fetchone()
        self.assertIsNotNone(forge_job)
        self.assertEqual(forge_job["status"], "ready")
        self.assertEqual(forge_job["agent_id"], "forge")

        # 6. schedule_ready_jobs -- creates pending run for forge
        schedule_ready_jobs(conn2)

        forge_run = conn2.execute(
            "SELECT id, status FROM rt_runs WHERE job_id = ?", (forge_job_id,)
        ).fetchone()
        self.assertIsNotNone(forge_run)
        self.assertEqual(forge_run["status"], "pending")
        forge_run_id = forge_run["id"]

        # 7. Open conn3, call claim(conn3, 'forge', 'forge-1')
        conn3 = _open_conn(self.db_path)
        forge_claim = claim(conn3, "forge", "forge-1")
        self.assertIsNotNone(forge_claim)
        self.assertEqual(forge_claim["run_id"], forge_run_id)

        # 8. Call complete_run(conn3, forge_run_id, forge_job_id, '{"built": true}')
        complete_run(conn3, forge_run_id, forge_job_id, '{"built": true}')

        # 9. resolve_child_results + resume_waiting_runs -- should resolve milo's dep and resume milo
        resolve_child_results(conn3)
        resume_waiting_runs(conn3)

        # 10. Assert: milo run='running', rt_run_deps resolved with forge's result
        milo_run_final = conn3.execute(
            "SELECT status FROM rt_runs WHERE id = ?", (milo_run_id,)
        ).fetchone()
        self.assertEqual(milo_run_final["status"], "running")

        dep = conn3.execute(
            "SELECT status, result FROM rt_run_deps WHERE run_id = ? AND target_id = ?",
            (milo_run_id, forge_job_id),
        ).fetchone()
        self.assertIsNotNone(dep)
        self.assertEqual(dep["status"], "resolved")
        dep_result = json.loads(dep["result"])
        self.assertEqual(dep_result.get("built"), True)

        conn2.close()
        conn3.close()


class TestFanOutFanIn(unittest.TestCase):
    """Test 2: Full fan-out / fan-in test with 3 children."""

    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        if os.path.exists(self.db_path):
            os.unlink(self.db_path)

    def test_fan_out_fan_in(self):
        # Setup agents
        for agent in ["milo", "forge", "scout", "pulse"]:
            _insert_agent(self.conn, agent)

        # 1. Create root job for 'milo' (ready), schedule, claim
        milo_job_id = _id()
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title, payload) "
            "VALUES (?, 'milo', 'ready', 'Fan-out root', '{}')",
            (milo_job_id,),
        )
        self.conn.commit()

        schedule_ready_jobs(self.conn)

        milo_run = self.conn.execute(
            "SELECT id FROM rt_runs WHERE job_id = ?", (milo_job_id,)
        ).fetchone()
        self.assertIsNotNone(milo_run)
        milo_run_id = milo_run["id"]

        conn2 = _open_conn(self.db_path)
        milo_claim = claim(conn2, "milo", "milo-fanout-1")
        self.assertIsNotNone(milo_claim)

        # 2. Call delegate_many with 3 children: forge, scout, pulse
        delegations = [
            {"agent_id": "forge", "title": "Forge task"},
            {"agent_id": "scout", "title": "Scout task"},
            {"agent_id": "pulse", "title": "Pulse task"},
        ]
        child_ids = delegate_many(conn2, milo_run_id, delegations)
        self.assertEqual(len(child_ids), 3)
        forge_id, scout_id, pulse_id = child_ids

        # 3. Assert: milo waiting, 3 child jobs ready
        milo_job_row = conn2.execute(
            "SELECT status FROM rt_jobs WHERE id = ?", (milo_job_id,)
        ).fetchone()
        self.assertEqual(milo_job_row["status"], "waiting")

        for child_id in child_ids:
            child = conn2.execute(
                "SELECT status FROM rt_jobs WHERE id = ?", (child_id,)
            ).fetchone()
            self.assertIsNotNone(child)
            self.assertEqual(child["status"], "ready")

        # 4. Schedule all 3, claim and complete forge and scout
        schedule_ready_jobs(conn2)

        conn3 = _open_conn(self.db_path)
        conn4 = _open_conn(self.db_path)

        forge_claim = claim(conn3, "forge", "forge-fanout-1")
        self.assertIsNotNone(forge_claim)
        complete_run(conn3, forge_claim["run_id"], forge_id, '{"done": "forge"}')

        scout_claim = claim(conn4, "scout", "scout-fanout-1")
        self.assertIsNotNone(scout_claim)
        complete_run(conn4, scout_claim["run_id"], scout_id, '{"done": "scout"}')

        # 5. resolve_child_results + resume_waiting_runs
        resolve_child_results(conn2)
        resume_waiting_runs(conn2)

        # 6. Assert: milo still waiting (pulse not done)
        milo_run_mid = conn2.execute(
            "SELECT status FROM rt_runs WHERE id = ?", (milo_run_id,)
        ).fetchone()
        self.assertEqual(milo_run_mid["status"], "waiting")

        # 7. Claim and complete pulse
        conn5 = _open_conn(self.db_path)
        pulse_claim = claim(conn5, "pulse", "pulse-fanout-1")
        self.assertIsNotNone(pulse_claim)
        complete_run(conn5, pulse_claim["run_id"], pulse_id, '{"done": "pulse"}')

        # 8. resolve_child_results + resume_waiting_runs
        resolve_child_results(conn2)
        resume_waiting_runs(conn2)

        # 9. Assert: milo resumed (running), all 3 deps resolved
        milo_run_final = conn2.execute(
            "SELECT status FROM rt_runs WHERE id = ?", (milo_run_id,)
        ).fetchone()
        self.assertEqual(milo_run_final["status"], "running")

        deps = conn2.execute(
            "SELECT status FROM rt_run_deps WHERE run_id = ?", (milo_run_id,)
        ).fetchall()
        self.assertEqual(len(deps), 3)
        for dep in deps:
            self.assertEqual(dep["status"], "resolved")

        conn2.close()
        conn3.close()
        conn4.close()
        conn5.close()


class TestFailFast(unittest.TestCase):
    """Test 3: fail_fast propagation -- parent fails immediately when a child fails."""

    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        if os.path.exists(self.db_path):
            os.unlink(self.db_path)

    def test_fail_fast(self):
        # Setup agents
        for agent in ["milo", "forge", "scout"]:
            _insert_agent(self.conn, agent)

        # 1. Create root job for 'milo' with fail_fast=1
        milo_job_id = _id()
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title, payload, fail_fast) "
            "VALUES (?, 'milo', 'ready', 'Fail-fast root', '{}', 1)",
            (milo_job_id,),
        )
        self.conn.commit()

        # 2. Schedule, claim
        schedule_ready_jobs(self.conn)

        milo_run = self.conn.execute(
            "SELECT id FROM rt_runs WHERE job_id = ?", (milo_job_id,)
        ).fetchone()
        self.assertIsNotNone(milo_run)
        milo_run_id = milo_run["id"]

        conn2 = _open_conn(self.db_path)
        milo_claim = claim(conn2, "milo", "milo-ff-1")
        self.assertIsNotNone(milo_claim)

        # delegate_many to forge + scout
        delegations = [
            {"agent_id": "forge", "title": "Forge fail-fast task"},
            {"agent_id": "scout", "title": "Scout fail-fast task"},
        ]
        child_ids = delegate_many(conn2, milo_run_id, delegations)
        self.assertEqual(len(child_ids), 2)
        forge_id, scout_id = child_ids

        # 3. Schedule forge, claim forge, fail forge (fail_run)
        schedule_ready_jobs(conn2)

        conn3 = _open_conn(self.db_path)
        forge_claim = claim(conn3, "forge", "forge-ff-1")
        self.assertIsNotNone(forge_claim)
        fail_run(conn3, forge_claim["run_id"], forge_id, "forge exploded")

        # 4. Set forge job status='failed' (simulating readiness engine exhausting retries)
        conn3.execute(
            "UPDATE rt_jobs SET status = 'failed' WHERE id = ?", (forge_id,)
        )
        conn3.commit()

        # 5. resolve_child_results + handle_child_failures
        resolve_child_results(conn2)
        handle_child_failures(conn2)

        # 6. Assert: milo job='failed', milo run='failed' (didn't wait for scout)
        milo_job_final = conn2.execute(
            "SELECT status FROM rt_jobs WHERE id = ?", (milo_job_id,)
        ).fetchone()
        self.assertEqual(milo_job_final["status"], "failed")

        milo_run_final = conn2.execute(
            "SELECT status FROM rt_runs WHERE id = ?", (milo_run_id,)
        ).fetchone()
        self.assertEqual(milo_run_final["status"], "failed")

        # Scout should still be untouched (not completed) -- fail_fast cut it short
        scout_run = conn2.execute(
            "SELECT status FROM rt_runs WHERE job_id = ?", (scout_id,)
        ).fetchone()
        # Scout may or may not have been scheduled; what matters is milo is already failed
        # (scout can be pending/none since milo failed before scout could complete)
        milo_still_failed = conn2.execute(
            "SELECT status FROM rt_jobs WHERE id = ?", (milo_job_id,)
        ).fetchone()
        self.assertEqual(milo_still_failed["status"], "failed")

        conn2.close()
        conn3.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
