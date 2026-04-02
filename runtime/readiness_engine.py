#!/usr/bin/env python3
"""readiness_engine.py -- HYDRA Runtime Scheduler Daemon.

Runs on a 30-second interval via launchd. Does NOT execute work.
Decides what's ready and wakes the right agent.

Usage: /usr/bin/python3 readiness_engine.py [--once] [--db PATH]
  --once: run one cycle and exit (for testing)
  --db:   override database path
"""
import argparse
import json
import logging
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rt_db import connect, generate_id, HYDRA_DB

LOG_DIR = os.path.expanduser("~/Library/Logs/claude-automation/hydra-runtime")
os.makedirs(LOG_DIR, exist_ok=True)

logging.basicConfig(
    filename=os.path.join(LOG_DIR, "readiness-engine.log"),
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s: %(message)s",
)
log = logging.getLogger("readiness")


def satisfy_deps(conn):
    """Mark job deps as satisfied when their dependency job is completed.

    For each job where ALL deps are now satisfied, transition to ready.
    """
    conn.execute("BEGIN IMMEDIATE")
    try:
        # Find pending deps whose dependency job is completed
        conn.execute("""
            UPDATE rt_job_deps
            SET status = 'satisfied', satisfied_at = datetime('now')
            WHERE status = 'pending'
              AND depends_on_id IN (
                  SELECT id FROM rt_jobs WHERE status = 'completed'
              )
        """)

        # For each job where ALL deps are satisfied, set status to ready
        conn.execute("""
            UPDATE rt_jobs
            SET status = 'ready'
            WHERE status = 'pending'
              AND id IN (
                  SELECT job_id FROM rt_job_deps
                  GROUP BY job_id
                  HAVING COUNT(*) = COUNT(CASE WHEN status = 'satisfied' THEN 1 END)
              )
        """)

        conn.commit()
        log.info("satisfy_deps: cycle complete")
    except Exception:
        conn.rollback()
        raise


def resolve_child_results(conn):
    """Resolve rt_run_deps with wait_type='child_result' when child job completes.

    Joins target_id to rt_jobs.id (NOT rt_runs.id).
    """
    conn.execute("BEGIN IMMEDIATE")
    try:
        # Find pending child_result deps where the child JOB is completed
        rows = conn.execute("""
            SELECT rd.id AS dep_id, j.result AS child_result, j.status AS child_status
            FROM rt_run_deps rd
            JOIN rt_jobs j ON rd.target_id = j.id
            WHERE rd.wait_type = 'child_result'
              AND rd.status = 'pending'
              AND j.status IN ('completed', 'failed')
        """).fetchall()

        for row in rows:
            if row["child_status"] == "completed":
                result = row["child_result"]
            else:
                result = json.dumps({"error": "child_job_failed"})

            conn.execute("""
                UPDATE rt_run_deps
                SET status = 'resolved', resolved_at = datetime('now'), result = ?
                WHERE id = ?
            """, (result, row["dep_id"]))

        conn.commit()
        log.info("resolve_child_results: resolved %d deps", len(rows))
    except Exception:
        conn.rollback()
        raise


def resume_waiting_runs(conn):
    """Resume runs in 'waiting' status where ALL rt_run_deps are resolved."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        # Find waiting runs where no pending deps remain
        run_ids = conn.execute("""
            SELECT r.id AS run_id, r.job_id
            FROM rt_runs r
            WHERE r.status = 'waiting'
              AND NOT EXISTS (
                  SELECT 1 FROM rt_run_deps rd
                  WHERE rd.run_id = r.id AND rd.status = 'pending'
              )
        """).fetchall()

        for row in run_ids:
            conn.execute(
                "UPDATE rt_runs SET status = 'running' WHERE id = ?",
                (row["run_id"],),
            )
            conn.execute(
                "UPDATE rt_jobs SET status = 'running' WHERE id = ?",
                (row["job_id"],),
            )

        conn.commit()
        log.info("resume_waiting_runs: resumed %d runs", len(run_ids))
    except Exception:
        conn.rollback()
        raise


def handle_child_failures(conn):
    """Handle fail_fast logic for parent jobs with failed child results."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        # Find waiting runs that have a resolved child_result dep with failure
        # AND the parent job has fail_fast=1
        rows = conn.execute("""
            SELECT DISTINCT r.id AS run_id, r.job_id
            FROM rt_runs r
            JOIN rt_jobs j ON r.job_id = j.id
            JOIN rt_run_deps rd ON rd.run_id = r.id
            WHERE r.status = 'waiting'
              AND j.fail_fast = 1
              AND rd.wait_type = 'child_result'
              AND rd.status = 'resolved'
              AND json_extract(rd.result, '$.error') IS NOT NULL
        """).fetchall()

        for row in rows:
            run_id = row["run_id"]
            job_id = row["job_id"]

            # Mark all remaining pending deps as resolved with error
            conn.execute("""
                UPDATE rt_run_deps
                SET status = 'resolved',
                    resolved_at = datetime('now'),
                    result = '{"error": "fail_fast_triggered"}'
                WHERE run_id = ? AND status = 'pending'
            """, (run_id,))

            # Fail the run and job
            conn.execute(
                "UPDATE rt_runs SET status = 'failed', error = 'fail_fast', finished_at = datetime('now') WHERE id = ?",
                (run_id,),
            )
            conn.execute(
                "UPDATE rt_jobs SET status = 'failed' WHERE id = ?",
                (job_id,),
            )

            # Insert job.failed event
            conn.execute(
                "INSERT INTO rt_events (id, job_id, run_id, event_type, payload) "
                "VALUES (?, ?, ?, 'job.failed', ?)",
                (generate_id(), job_id, run_id, json.dumps({"reason": "fail_fast"})),
            )

        conn.commit()
        log.info("handle_child_failures: handled %d fail_fast jobs", len(rows))
    except Exception:
        conn.rollback()
        raise


def detect_stale_claims(conn):
    """Find expired run claims and handle retry or failure."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        stale = conn.execute("""
            SELECT rc.run_id, r.job_id, rc.worker_id
            FROM rt_run_claims rc
            JOIN rt_runs r ON rc.run_id = r.id
            WHERE julianday('now') - julianday(rc.last_heartbeat) > rc.lease_ttl_sec / 86400.0
        """).fetchall()

        for row in stale:
            run_id = row["run_id"]
            job_id = row["job_id"]

            # Delete the stale claim
            conn.execute("DELETE FROM rt_run_claims WHERE run_id = ?", (run_id,))

            # Fail the orphaned run
            conn.execute(
                "UPDATE rt_runs SET status = 'failed', error = 'lease_expired', "
                "finished_at = datetime('now') WHERE id = ?",
                (run_id,),
            )

            # Check retry budget
            job = conn.execute(
                "SELECT retry_count, max_retries FROM rt_jobs WHERE id = ?",
                (job_id,),
            ).fetchone()

            if job["retry_count"] < job["max_retries"]:
                conn.execute(
                    "UPDATE rt_jobs SET retry_count = retry_count + 1, status = 'ready' WHERE id = ?",
                    (job_id,),
                )
            else:
                conn.execute(
                    "UPDATE rt_jobs SET status = 'failed' WHERE id = ?",
                    (job_id,),
                )
                conn.execute(
                    "INSERT INTO rt_events (id, job_id, event_type, payload) "
                    "VALUES (?, ?, 'job.failed', ?)",
                    (generate_id(), job_id, json.dumps({"reason": "retries_exhausted"})),
                )

        conn.commit()
        log.info("detect_stale_claims: processed %d stale claims", len(stale))
    except Exception:
        conn.rollback()
        raise


def schedule_ready_jobs(conn):
    """Create pending runs for ready jobs that have no active runs."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        ready_jobs = conn.execute(
            "SELECT id FROM rt_jobs WHERE status = 'ready'"
        ).fetchall()

        scheduled = 0
        for job in ready_jobs:
            job_id = job["id"]

            # Check no active runs exist (pending, running, or waiting)
            existing = conn.execute(
                "SELECT COUNT(*) AS cnt FROM rt_runs "
                "WHERE job_id = ? AND status IN ('pending', 'running', 'waiting')",
                (job_id,),
            ).fetchone()

            if existing["cnt"] == 0:
                conn.execute(
                    "INSERT INTO rt_runs (id, job_id, status) VALUES (?, ?, 'pending')",
                    (generate_id(), job_id),
                )
                scheduled += 1

        conn.commit()
        log.info("schedule_ready_jobs: scheduled %d runs", scheduled)
    except Exception:
        conn.rollback()
        raise


def wake_agents(conn):
    """Kick agents via launchctl for high-priority or child-spawned jobs."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        pending_runs = conn.execute("""
            SELECT r.id AS run_id, j.id AS job_id, j.agent_id, j.parent_job_id, j.priority
            FROM rt_runs r
            JOIN rt_jobs j ON r.job_id = j.id
            WHERE r.status = 'pending'
        """).fetchall()

        uid = os.getuid()
        for row in pending_runs:
            agent_id = row["agent_id"]
            needs_kick = False

            if row["parent_job_id"] is not None:
                # Check if parent job is waiting
                parent = conn.execute(
                    "SELECT status FROM rt_jobs WHERE id = ?",
                    (row["parent_job_id"],),
                ).fetchone()
                if parent and parent["status"] == "waiting":
                    needs_kick = True

            if row["priority"] == 1:
                needs_kick = True

            if needs_kick:
                service = "gui/%d/com.hydra.agent-%s" % (uid, agent_id)
                try:
                    subprocess.run(
                        ["launchctl", "kickstart", service],
                        capture_output=True,
                    )
                    log.info("wake_agents: kicked %s for run %s", agent_id, row["run_id"])
                except Exception as e:
                    log.warning("wake_agents: failed to kick %s: %s", agent_id, e)

        conn.commit()
    except Exception:
        conn.rollback()
        raise


def deliver_events(conn):
    """Drain undelivered events (mark as delivered, log them)."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        events = conn.execute(
            "SELECT id, job_id, run_id, event_type, payload FROM rt_events "
            "WHERE delivered_at IS NULL"
        ).fetchall()

        for ev in events:
            conn.execute(
                "UPDATE rt_events SET delivered_at = datetime('now') WHERE id = ?",
                (ev["id"],),
            )
            log.info(
                "deliver_events: %s job=%s run=%s payload=%s",
                ev["event_type"],
                ev["job_id"],
                ev["run_id"],
                ev["payload"],
            )

        conn.commit()
        log.info("deliver_events: delivered %d events", len(events))
    except Exception:
        conn.rollback()
        raise


def run_cycle(db_path=None):
    """Run one full scheduling cycle."""
    conn = connect(db_path)
    try:
        satisfy_deps(conn)
        resolve_child_results(conn)
        handle_child_failures(conn)
        resume_waiting_runs(conn)
        detect_stale_claims(conn)
        schedule_ready_jobs(conn)
        wake_agents(conn)
        deliver_events(conn)
        log.info("run_cycle: complete")
    finally:
        conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="HYDRA Readiness Engine")
    parser.add_argument("--once", action="store_true", help="Run one cycle and exit")
    parser.add_argument("--db", type=str, default=None, help="Override database path")
    args = parser.parse_args()

    if args.once:
        run_cycle(db_path=args.db)
    else:
        import time
        while True:
            try:
                run_cycle(db_path=args.db)
            except Exception as e:
                log.error("run_cycle failed: %s", e)
            time.sleep(30)
