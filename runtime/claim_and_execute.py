#!/usr/bin/env python3
"""claim_and_execute.py -- Atomic claim and single-shot execution.

Called by agent-runner.sh during heartbeat cycle.
Exit codes: 0 = executed, 2 = no work available, 1 = error.
"""
import json
import os
import subprocess
import sys
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rt_db import connect, generate_id

ADAPTER_SCRIPT = os.path.expanduser("~/.hydra/tools/hydra-adapter.sh")
EXECUTE_TIMEOUT = 300  # seconds


def claim(conn, agent_id: str, worker_id: str) -> Optional[dict]:
    """Atomically claim the next pending run for the given agent.

    Returns a dict with run_id, job_id, title, payload on success.
    Returns None if no work is available or the race was lost.
    """
    try:
        conn.execute("BEGIN IMMEDIATE")
    except Exception:
        return None

    try:
        row = conn.execute(
            """
            SELECT r.id AS run_id, j.id AS job_id, j.title, j.payload
            FROM rt_runs r
            JOIN rt_jobs j ON j.id = r.job_id
            WHERE j.agent_id = ?
              AND r.status = 'pending'
            ORDER BY j.priority DESC, r.created_at ASC
            LIMIT 1
            """,
            (agent_id,),
        ).fetchone()

        if row is None:
            conn.execute("ROLLBACK")
            return None

        run_id = row["run_id"]
        job_id = row["job_id"]

        try:
            conn.execute(
                "INSERT INTO rt_run_claims (run_id, worker_id) VALUES (?, ?)",
                (run_id, worker_id),
            )
        except Exception:
            # PK conflict -- another worker already claimed this run
            conn.execute("ROLLBACK")
            return None

        conn.execute(
            "UPDATE rt_runs SET status='running', started_at=datetime('now') WHERE id=?",
            (run_id,),
        )
        conn.execute(
            "UPDATE rt_jobs SET status='running' WHERE id=?",
            (job_id,),
        )
        conn.execute("COMMIT")

        return {
            "run_id": run_id,
            "job_id": job_id,
            "title": row["title"],
            "payload": row["payload"],
        }

    except Exception:
        try:
            conn.execute("ROLLBACK")
        except Exception:
            pass
        return None


def complete_run(conn, run_id: str, job_id: str, result_json: str) -> None:
    """Mark a run and its parent job as completed, emit run.completed event."""
    conn.execute("BEGIN IMMEDIATE")
    conn.execute(
        "UPDATE rt_runs SET status='completed', finished_at=datetime('now'), result=? WHERE id=?",
        (result_json, run_id),
    )
    conn.execute(
        "UPDATE rt_jobs SET status='completed', result=? WHERE id=?",
        (result_json, job_id),
    )
    conn.execute(
        "DELETE FROM rt_run_claims WHERE run_id=?",
        (run_id,),
    )
    conn.execute(
        "INSERT INTO rt_events (id, job_id, run_id, event_type, payload) VALUES (?, ?, ?, 'run.completed', ?)",
        (generate_id(), job_id, run_id, json.dumps({"result": result_json})),
    )
    conn.execute("COMMIT")


def fail_run(conn, run_id: str, job_id: str, error_msg: str) -> None:
    """Mark a run as failed, increment job retry_count, emit run.failed event.

    Does NOT set job status -- the readiness engine handles transitioning
    the job to 'ready' (retry) or 'failed' (exhausted) on its next cycle.
    """
    conn.execute("BEGIN IMMEDIATE")
    conn.execute(
        "UPDATE rt_runs SET status='failed', finished_at=datetime('now'), error=? WHERE id=?",
        (error_msg, run_id),
    )
    conn.execute(
        "UPDATE rt_jobs SET retry_count = retry_count + 1 WHERE id=?",
        (job_id,),
    )
    conn.execute(
        "DELETE FROM rt_run_claims WHERE run_id=?",
        (run_id,),
    )
    conn.execute(
        "INSERT INTO rt_events (id, job_id, run_id, event_type, payload) VALUES (?, ?, ?, 'run.failed', ?)",
        (generate_id(), job_id, run_id, json.dumps({"error": error_msg})),
    )
    conn.execute("COMMIT")


def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: claim_and_execute.py <agent_id>", file=sys.stderr)
        sys.exit(1)

    agent_id = sys.argv[1]
    worker_id = f"{agent_id}-{os.getpid()}"

    conn = connect()

    run_info = claim(conn, agent_id, worker_id)
    if run_info is None:
        conn.close()
        sys.exit(2)

    print(
        f"[claim_and_execute] claimed run={run_info['run_id']} job={run_info['job_id']} "
        f"title={run_info['title']!r}"
    )

    env = os.environ.copy()
    env["RT_JOB_PAYLOAD"] = run_info["payload"]
    env["RT_RUN_ID"] = run_info["run_id"]

    exit_code = 0
    stdout_buf = b""
    stderr_buf = b""

    try:
        proc = subprocess.run(
            [ADAPTER_SCRIPT, "execute", agent_id, run_info["job_id"]],
            env=env,
            capture_output=True,
            timeout=EXECUTE_TIMEOUT,
        )
        exit_code = proc.returncode
        stdout_buf = proc.stdout
        stderr_buf = proc.stderr
    except subprocess.TimeoutExpired as exc:
        exit_code = 1
        stdout_buf = exc.stdout or b""
        stderr_buf = exc.stderr or b""
        error_msg = f"timeout after {EXECUTE_TIMEOUT}s"
        fail_run(conn, run_info["run_id"], run_info["job_id"], error_msg)
        conn.close()
        print(f"[claim_and_execute] TIMEOUT: {error_msg}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        exit_code = 1
        error_msg = str(exc)
        fail_run(conn, run_info["run_id"], run_info["job_id"], error_msg)
        conn.close()
        print(f"[claim_and_execute] ERROR: {error_msg}", file=sys.stderr)
        sys.exit(1)

    if exit_code == 0:
        result = {
            "exit_code": 0,
            "stdout": stdout_buf.decode("utf-8", errors="replace"),
        }
        complete_run(conn, run_info["run_id"], run_info["job_id"], json.dumps(result))
        print(f"[claim_and_execute] completed run={run_info['run_id']}")
    else:
        combined = (stdout_buf + b"\n" + stderr_buf).decode("utf-8", errors="replace").strip()
        error_msg = f"exit_code={exit_code}: {combined[:500]}"
        fail_run(conn, run_info["run_id"], run_info["job_id"], error_msg)
        print(f"[claim_and_execute] failed run={run_info['run_id']}: {error_msg}", file=sys.stderr)

    conn.close()
    sys.exit(0 if exit_code == 0 else 1)


if __name__ == "__main__":
    main()
