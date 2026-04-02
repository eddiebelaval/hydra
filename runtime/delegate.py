#!/usr/bin/env python3
"""delegate.py -- Agent delegation API.

Allows a running agent to hand work to another agent and wait for the result.
Supports both single delegation (chain) and fan-out (parallel).
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rt_db import connect, generate_id


def delegate(conn, parent_run_id, agent_id, title, payload=None, priority=0, fail_fast=False):
    """Delegate work to another agent and pause the parent run.

    Creates a child job for agent_id, a run dep on the parent run,
    and pauses both the parent run and parent job.

    Returns the child_job_id.
    """
    child_job_id = generate_id()
    dep_id = generate_id()
    event_id = generate_id()
    payload_json = json.dumps(payload) if payload else '{}'

    conn.execute("BEGIN IMMEDIATE")
    try:
        # Look up parent job from parent run
        row = conn.execute(
            "SELECT job_id FROM rt_runs WHERE id = ?", (parent_run_id,)
        ).fetchone()
        if row is None:
            raise ValueError(f"No run found with id {parent_run_id}")
        parent_job_id = row["job_id"]

        # Create child job
        conn.execute(
            "INSERT INTO rt_jobs (id, parent_job_id, agent_id, status, priority, fail_fast, title, payload) "
            "VALUES (?, ?, ?, 'ready', ?, ?, ?, ?)",
            (child_job_id, parent_job_id, agent_id, priority, 1 if fail_fast else 0, title, payload_json),
        )

        # Create run dep: parent run waits on child job
        conn.execute(
            "INSERT INTO rt_run_deps (id, run_id, wait_type, target_id, status) "
            "VALUES (?, ?, 'child_result', ?, 'pending')",
            (dep_id, parent_run_id, child_job_id),
        )

        # Pause parent run and job
        conn.execute(
            "UPDATE rt_runs SET status = 'waiting' WHERE id = ?",
            (parent_run_id,),
        )
        conn.execute(
            "UPDATE rt_jobs SET status = 'waiting' WHERE id = ?",
            (parent_job_id,),
        )

        # Insert delegation.requested event
        conn.execute(
            "INSERT INTO rt_events (id, job_id, run_id, event_type, payload) "
            "VALUES (?, ?, ?, 'delegation.requested', ?)",
            (event_id, parent_job_id, parent_run_id,
             json.dumps({"child_job_id": child_job_id, "agent_id": agent_id, "title": title})),
        )

        conn.commit()
    except Exception:
        conn.rollback()
        raise

    return child_job_id


def delegate_many(conn, parent_run_id, delegations):
    """Delegate work to multiple agents in a single transaction.

    delegations is a list of dicts with keys: agent_id, title, payload (optional), priority (optional).
    Returns a list of child_job_ids.
    """
    child_job_ids = []

    conn.execute("BEGIN IMMEDIATE")
    try:
        # Look up parent job from parent run
        row = conn.execute(
            "SELECT job_id FROM rt_runs WHERE id = ?", (parent_run_id,)
        ).fetchone()
        if row is None:
            raise ValueError(f"No run found with id {parent_run_id}")
        parent_job_id = row["job_id"]

        for d in delegations:
            child_job_id = generate_id()
            dep_id = generate_id()
            agent_id = d["agent_id"]
            title = d["title"]
            payload = d.get("payload")
            priority = d.get("priority", 0)
            payload_json = json.dumps(payload) if payload else '{}'

            # Create child job
            conn.execute(
                "INSERT INTO rt_jobs (id, parent_job_id, agent_id, status, priority, title, payload) "
                "VALUES (?, ?, ?, 'ready', ?, ?, ?)",
                (child_job_id, parent_job_id, agent_id, priority, title, payload_json),
            )

            # Create run dep
            conn.execute(
                "INSERT INTO rt_run_deps (id, run_id, wait_type, target_id, status) "
                "VALUES (?, ?, 'child_result', ?, 'pending')",
                (dep_id, parent_run_id, child_job_id),
            )

            child_job_ids.append(child_job_id)

        # Pause parent run and job
        conn.execute(
            "UPDATE rt_runs SET status = 'waiting' WHERE id = ?",
            (parent_run_id,),
        )
        conn.execute(
            "UPDATE rt_jobs SET status = 'waiting' WHERE id = ?",
            (parent_job_id,),
        )

        # Insert delegation.requested event for the fan-out
        event_id = generate_id()
        conn.execute(
            "INSERT INTO rt_events (id, job_id, run_id, event_type, payload) "
            "VALUES (?, ?, ?, 'delegation.requested', ?)",
            (event_id, parent_job_id, parent_run_id,
             json.dumps({"child_job_ids": child_job_ids, "count": len(delegations)})),
        )

        conn.commit()
    except Exception:
        conn.rollback()
        raise

    return child_job_ids


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: delegate.py <parent-run-id> <agent> <title> [payload-json]", file=sys.stderr)
        sys.exit(1)

    parent_run_id = sys.argv[1]
    agent_id = sys.argv[2]
    title = sys.argv[3]
    payload = json.loads(sys.argv[4]) if len(sys.argv) > 4 else None

    conn = connect()
    try:
        child_job_id = delegate(conn, parent_run_id, agent_id, title, payload)
        print(child_job_id)
    finally:
        conn.close()
