#!/usr/bin/env python3
"""Tests for rt_db module."""
import os
import sqlite3
import tempfile
import unittest

import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from rt_db import connect, generate_id, JOB_STATUSES, RUN_STATUSES


class TestConnect(unittest.TestCase):
    def test_connect_sets_wal_mode(self):
        with tempfile.NamedTemporaryFile(suffix='.db', delete=False) as f:
            db_path = f.name
        try:
            conn = connect(db_path)
            mode = conn.execute("PRAGMA journal_mode;").fetchone()[0]
            self.assertEqual(mode, 'wal')
            conn.close()
        finally:
            for ext in ('', '-wal', '-shm'):
                try:
                    os.unlink(db_path + ext)
                except FileNotFoundError:
                    pass

    def test_connect_sets_busy_timeout(self):
        with tempfile.NamedTemporaryFile(suffix='.db', delete=False) as f:
            db_path = f.name
        try:
            conn = connect(db_path)
            timeout = conn.execute("PRAGMA busy_timeout;").fetchone()[0]
            self.assertEqual(timeout, 5000)
            conn.close()
        finally:
            for ext in ('', '-wal', '-shm'):
                try:
                    os.unlink(db_path + ext)
                except FileNotFoundError:
                    pass

    def test_connect_enables_foreign_keys(self):
        with tempfile.NamedTemporaryFile(suffix='.db', delete=False) as f:
            db_path = f.name
        try:
            conn = connect(db_path)
            fk = conn.execute("PRAGMA foreign_keys;").fetchone()[0]
            self.assertEqual(fk, 1)
            conn.close()
        finally:
            for ext in ('', '-wal', '-shm'):
                try:
                    os.unlink(db_path + ext)
                except FileNotFoundError:
                    pass


class TestGenerateId(unittest.TestCase):
    def test_returns_32_char_hex(self):
        id_ = generate_id()
        self.assertEqual(len(id_), 32)
        self.assertTrue(all(c in '0123456789abcdef' for c in id_))

    def test_ids_are_unique(self):
        ids = {generate_id() for _ in range(100)}
        self.assertEqual(len(ids), 100)


class TestConstants(unittest.TestCase):
    def test_job_statuses(self):
        self.assertIn('pending', JOB_STATUSES)
        self.assertIn('ready', JOB_STATUSES)
        self.assertIn('running', JOB_STATUSES)
        self.assertIn('waiting', JOB_STATUSES)
        self.assertIn('completed', JOB_STATUSES)
        self.assertIn('failed', JOB_STATUSES)

    def test_run_statuses(self):
        self.assertIn('pending', RUN_STATUSES)
        self.assertIn('running', RUN_STATUSES)
        self.assertIn('waiting', RUN_STATUSES)
        self.assertIn('completed', RUN_STATUSES)
        self.assertIn('failed', RUN_STATUSES)


if __name__ == '__main__':
    unittest.main()
