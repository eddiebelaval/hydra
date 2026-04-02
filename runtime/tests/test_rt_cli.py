#!/usr/bin/env python3
"""Tests for rt_cli.py -- HYDRA Runtime Engine CLI."""
import argparse
import io
import json
import os
import sys
import tempfile
import unittest

INIT_PATH = os.path.expanduser("~/.hydra/init-db.sql")
MIGRATION_PATH = os.path.expanduser("~/.hydra/migrations/003-runtime-engine.sql")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


def create_test_db():
    import sqlite3
    db_path = tempfile.mktemp(suffix=".db")
    conn = sqlite3.connect(db_path)
    conn.executescript(open(INIT_PATH).read())
    conn.executescript(open(MIGRATION_PATH).read())
    conn.row_factory = sqlite3.Row
    return db_path, conn


class TestCreateJob(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_create_job(self):
        """cmd_create with agent='forge' and title='Test job' inserts a row in rt_jobs."""
        from rt_cli import cmd_create
        args = argparse.Namespace(
            agent='forge',
            title='Test job',
            payload=None,
            priority=0,
            depends_on=None,
        )
        cmd_create(args, conn=self.conn)
        row = self.conn.execute(
            "SELECT * FROM rt_jobs WHERE agent_id = 'forge' AND title = 'Test job'"
        ).fetchone()
        self.assertIsNotNone(row)

    def test_create_job_no_deps_is_ready(self):
        """Job created with no dependencies gets status='ready'."""
        from rt_cli import cmd_create
        args = argparse.Namespace(
            agent='forge',
            title='No-dep job',
            payload=None,
            priority=0,
            depends_on=None,
        )
        cmd_create(args, conn=self.conn)
        row = self.conn.execute(
            "SELECT status FROM rt_jobs WHERE title = 'No-dep job'"
        ).fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(row['status'], 'ready')

    def test_create_job_with_deps_is_pending(self):
        """Job created with depends_on gets status='pending' and rt_job_deps row exists."""
        from rt_cli import cmd_create

        # Create job A (no deps -> ready)
        args_a = argparse.Namespace(
            agent='forge',
            title='Job A',
            payload=None,
            priority=0,
            depends_on=None,
        )
        cmd_create(args_a, conn=self.conn)
        job_a = self.conn.execute(
            "SELECT id FROM rt_jobs WHERE title = 'Job A'"
        ).fetchone()
        self.assertIsNotNone(job_a)
        a_id = job_a['id']

        # Create job B with depends_on=[a_id]
        args_b = argparse.Namespace(
            agent='forge',
            title='Job B',
            payload=None,
            priority=0,
            depends_on=[a_id],
        )
        cmd_create(args_b, conn=self.conn)

        job_b = self.conn.execute(
            "SELECT id, status FROM rt_jobs WHERE title = 'Job B'"
        ).fetchone()
        self.assertIsNotNone(job_b)
        self.assertEqual(job_b['status'], 'pending')

        dep_row = self.conn.execute(
            "SELECT * FROM rt_job_deps WHERE job_id = ? AND depends_on_id = ?",
            (job_b['id'], a_id),
        ).fetchone()
        self.assertIsNotNone(dep_row)


class TestStatusCommand(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_status_shows_job(self):
        """cmd_status output contains the job title and status."""
        from rt_cli import cmd_create, cmd_status

        args_create = argparse.Namespace(
            agent='milo',
            title='Status Test Job',
            payload=None,
            priority=0,
            depends_on=None,
        )
        cmd_create(args_create, conn=self.conn)

        job = self.conn.execute(
            "SELECT id FROM rt_jobs WHERE title = 'Status Test Job'"
        ).fetchone()
        self.assertIsNotNone(job)

        args_status = argparse.Namespace(job_id=job['id'])

        captured = io.StringIO()
        old_stdout = sys.stdout
        sys.stdout = captured
        try:
            cmd_status(args_status, conn=self.conn)
        finally:
            sys.stdout = old_stdout

        output = captured.getvalue()
        self.assertIn('Status Test Job', output)
        self.assertIn('ready', output)


class TestDepsCommand(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_add_deps(self):
        """cmd_deps inserts an rt_job_deps row from job B to job A."""
        from rt_cli import cmd_create, cmd_deps

        args_a = argparse.Namespace(
            agent='forge',
            title='Dep Target A',
            payload=None,
            priority=0,
            depends_on=None,
        )
        cmd_create(args_a, conn=self.conn)
        job_a = self.conn.execute(
            "SELECT id FROM rt_jobs WHERE title = 'Dep Target A'"
        ).fetchone()

        args_b = argparse.Namespace(
            agent='forge',
            title='Dep Source B',
            payload=None,
            priority=0,
            depends_on=None,
        )
        cmd_create(args_b, conn=self.conn)
        job_b = self.conn.execute(
            "SELECT id FROM rt_jobs WHERE title = 'Dep Source B'"
        ).fetchone()

        args_deps = argparse.Namespace(
            job_id=job_b['id'],
            on=job_a['id'],
        )
        cmd_deps(args_deps, conn=self.conn)

        dep_row = self.conn.execute(
            "SELECT * FROM rt_job_deps WHERE job_id = ? AND depends_on_id = ?",
            (job_b['id'], job_a['id']),
        ).fetchone()
        self.assertIsNotNone(dep_row)


class TestResolveCommand(unittest.TestCase):
    def setUp(self):
        self.db_path, self.conn = create_test_db()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.db_path)

    def test_resolve_run_dep(self):
        """cmd_resolve sets rt_run_deps status to 'resolved'."""
        from rt_cli import cmd_resolve
        from rt_db import generate_id

        # Need a job and run first (foreign key constraints)
        job_id = generate_id()
        run_id = generate_id()
        dep_id = generate_id()

        self.conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, status, title) VALUES (?, 'milo', 'waiting', 'Resolve Test Job')",
            (job_id,),
        )
        self.conn.execute(
            "INSERT INTO rt_runs (id, job_id, status) VALUES (?, ?, 'waiting')",
            (run_id, job_id),
        )
        self.conn.execute(
            "INSERT INTO rt_run_deps (id, run_id, wait_type, target_id, status) "
            "VALUES (?, ?, 'human_input', 'n/a', 'pending')",
            (dep_id, run_id),
        )
        self.conn.commit()

        args = argparse.Namespace(
            run_dep_id=dep_id,
            result=json.dumps({'ok': True}),
        )
        cmd_resolve(args, conn=self.conn)

        row = self.conn.execute(
            "SELECT status FROM rt_run_deps WHERE id = ?", (dep_id,)
        ).fetchone()
        self.assertEqual(row['status'], 'resolved')


if __name__ == '__main__':
    unittest.main(verbosity=2)
