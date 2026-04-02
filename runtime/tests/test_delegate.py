#!/usr/bin/env python3
"""Tests for the HYDRA delegation module."""
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


class TestDelegateCreatesChildJob(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_delegate_creates_child_job(self):
        """delegate() creates a child job with parent_job_id set, agent_id='scout', status='ready'."""
        from delegate import delegate

        parent_job_id = _id()
        parent_run_id = _id()

        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'running', 'Parent Job')",
            (parent_job_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_runs (id, job_id, status) VALUES (?, ?, 'running')",
            (parent_run_id, parent_job_id),
        )
        self.conn.commit()

        child_job_id = delegate(
            self.conn, parent_run_id, 'scout', 'Research competitors',
            {'topic': 'pricing'},
        )

        child = self.conn.execute(
            "SELECT * FROM rt_jobs WHERE id = ?", (child_job_id,)
        ).fetchone()
        self.assertIsNotNone(child)
        self.assertEqual(child["parent_job_id"], parent_job_id)
        self.assertEqual(child["agent_id"], "scout")
        self.assertEqual(child["status"], "ready")
        self.assertEqual(child["title"], "Research competitors")
        self.assertEqual(json.loads(child["payload"]), {"topic": "pricing"})


class TestDelegateCreatesRunDep(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_delegate_creates_run_dep(self):
        """delegate() creates an rt_run_deps row with run_id=parent_run_id, target_id=child_job_id."""
        from delegate import delegate

        parent_job_id = _id()
        parent_run_id = _id()

        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'running', 'Parent Job')",
            (parent_job_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_runs (id, job_id, status) VALUES (?, ?, 'running')",
            (parent_run_id, parent_job_id),
        )
        self.conn.commit()

        child_job_id = delegate(
            self.conn, parent_run_id, 'scout', 'Research competitors',
            {'topic': 'pricing'},
        )

        dep = self.conn.execute(
            "SELECT * FROM rt_run_deps WHERE run_id = ? AND target_id = ?",
            (parent_run_id, child_job_id),
        ).fetchone()
        self.assertIsNotNone(dep)
        self.assertEqual(dep["wait_type"], "child_result")
        self.assertEqual(dep["status"], "pending")


class TestDelegatePausesParent(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_delegate_pauses_parent(self):
        """After delegate(), parent run status='waiting', parent job status='waiting'."""
        from delegate import delegate

        parent_job_id = _id()
        parent_run_id = _id()

        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'running', 'Parent Job')",
            (parent_job_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_runs (id, job_id, status) VALUES (?, ?, 'running')",
            (parent_run_id, parent_job_id),
        )
        self.conn.commit()

        delegate(self.conn, parent_run_id, 'scout', 'Research competitors')

        parent_run = self.conn.execute(
            "SELECT status FROM rt_runs WHERE id = ?", (parent_run_id,)
        ).fetchone()
        self.assertEqual(parent_run["status"], "waiting")

        parent_job = self.conn.execute(
            "SELECT status FROM rt_jobs WHERE id = ?", (parent_job_id,)
        ).fetchone()
        self.assertEqual(parent_job["status"], "waiting")


class TestDelegateManyCreatesMultiple(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_delegate_many_creates_multiple(self):
        """delegate_many() with 3 delegations creates 3 child jobs and 3 rt_run_deps."""
        from delegate import delegate_many

        parent_job_id = _id()
        parent_run_id = _id()

        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'running', 'Parent Job')",
            (parent_job_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_runs (id, job_id, status) VALUES (?, ?, 'running')",
            (parent_run_id, parent_job_id),
        )
        self.conn.commit()

        delegations = [
            {"agent_id": "forge", "title": "Build widget", "payload": {"type": "ui"}},
            {"agent_id": "scout", "title": "Research market", "payload": {"topic": "trends"}},
            {"agent_id": "pulse", "title": "Check infra", "payload": {"target": "prod"}},
        ]

        child_ids = delegate_many(self.conn, parent_run_id, delegations)
        self.assertEqual(len(child_ids), 3)

        children = self.conn.execute(
            "SELECT * FROM rt_jobs WHERE parent_job_id = ?", (parent_job_id,)
        ).fetchall()
        self.assertEqual(len(children), 3)

        deps = self.conn.execute(
            "SELECT * FROM rt_run_deps WHERE run_id = ?", (parent_run_id,)
        ).fetchall()
        self.assertEqual(len(deps), 3)


class TestDelegateManySingleTransaction(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_delegate_many_single_transaction(self):
        """All 3 children and deps are created atomically after delegate_many succeeds."""
        from delegate import delegate_many

        parent_job_id = _id()
        parent_run_id = _id()

        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'running', 'Parent Job')",
            (parent_job_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_runs (id, job_id, status) VALUES (?, ?, 'running')",
            (parent_run_id, parent_job_id),
        )
        self.conn.commit()

        delegations = [
            {"agent_id": "forge", "title": "Build A"},
            {"agent_id": "scout", "title": "Research B"},
            {"agent_id": "pulse", "title": "Check C"},
        ]

        child_ids = delegate_many(self.conn, parent_run_id, delegations)

        # Verify all exist (atomicity -- if any failed, none should exist)
        for cid in child_ids:
            job = self.conn.execute(
                "SELECT * FROM rt_jobs WHERE id = ?", (cid,)
            ).fetchone()
            self.assertIsNotNone(job)
            self.assertEqual(job["status"], "ready")

            dep = self.conn.execute(
                "SELECT * FROM rt_run_deps WHERE target_id = ?", (cid,)
            ).fetchone()
            self.assertIsNotNone(dep)
            self.assertEqual(dep["status"], "pending")

        # Parent should be waiting
        parent_run = self.conn.execute(
            "SELECT status FROM rt_runs WHERE id = ?", (parent_run_id,)
        ).fetchone()
        self.assertEqual(parent_run["status"], "waiting")


class TestChildCompletionResolvesParentDep(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_child_completion_resolves_parent_dep(self):
        """Complete child job -> resolve_child_results -> dep resolved with child's result."""
        from readiness_engine import resolve_child_results

        parent_job_id = _id()
        child_job_id = _id()
        parent_run_id = _id()
        dep_id = _id()

        # Parent waiting
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'waiting', 'Parent Job')",
            (parent_job_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_runs (id, job_id, status) VALUES (?, ?, 'waiting')",
            (parent_run_id, parent_job_id),
        )

        # Child completed with result
        child_result = json.dumps({"answer": 42})
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title, result, parent_job_id) "
            "VALUES (?, 'scout', 'completed', 'Child Job', ?, ?)",
            (child_job_id, child_result, parent_job_id),
        )

        # rt_run_deps: target_id = child JOB id
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


class TestFanInWaitsForAll(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_fan_in_waits_for_all(self):
        """Parent with 3 children only resumes when ALL children complete."""
        from readiness_engine import resolve_child_results, resume_waiting_runs

        parent_job_id = _id()
        parent_run_id = _id()
        child_ids = [_id(), _id(), _id()]
        dep_ids = [_id(), _id(), _id()]

        # Parent waiting
        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'waiting', 'Parent Job')",
            (parent_job_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_runs (id, job_id, status) VALUES (?, ?, 'waiting')",
            (parent_run_id, parent_job_id),
        )

        agents = ['forge', 'scout', 'pulse']
        for i, (cid, did, agent) in enumerate(zip(child_ids, dep_ids, agents)):
            self.conn.execute(
                "INSERT INTO rt_jobs (id, agent_id, status, title, parent_job_id) "
                "VALUES (?, ?, 'running', ?, ?)",
                (cid, agent, f"Child {i+1}", parent_job_id),
            )
            self.conn.execute(
                "INSERT INTO rt_run_deps (id, run_id, wait_type, target_id, status) "
                "VALUES (?, ?, 'child_result', ?, 'pending')",
                (did, parent_run_id, cid),
            )
        self.conn.commit()

        # Complete children 1 and 2
        for cid in child_ids[:2]:
            self.conn.execute(
                "UPDATE rt_jobs SET status='completed', result=? WHERE id=?",
                (json.dumps({"done": True}), cid),
            )
        self.conn.commit()

        resolve_child_results(self.conn)
        resume_waiting_runs(self.conn)

        # Parent still waiting (child 3 not done)
        parent_run = self.conn.execute(
            "SELECT status FROM rt_runs WHERE id = ?", (parent_run_id,)
        ).fetchone()
        self.assertEqual(parent_run["status"], "waiting")

        # Complete child 3
        self.conn.execute(
            "UPDATE rt_jobs SET status='completed', result=? WHERE id=?",
            (json.dumps({"done": True}), child_ids[2]),
        )
        self.conn.commit()

        resolve_child_results(self.conn)
        resume_waiting_runs(self.conn)

        # Parent should now be running
        parent_run = self.conn.execute(
            "SELECT status FROM rt_runs WHERE id = ?", (parent_run_id,)
        ).fetchone()
        self.assertEqual(parent_run["status"], "running")

        parent_job = self.conn.execute(
            "SELECT status FROM rt_jobs WHERE id = ?", (parent_job_id,)
        ).fetchone()
        self.assertEqual(parent_job["status"], "running")


if __name__ == "__main__":
    unittest.main()
