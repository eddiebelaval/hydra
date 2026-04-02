#!/usr/bin/env python3
"""rt_cli.py -- HYDRA Runtime Engine CLI.

Commands:
  create <agent> <title> [--payload JSON] [--priority 0|1] [--depends-on JOB_ID...]
  status [job-id]
  deps <job-id> --on <other-job-id>
  resolve <run-dep-id> --result JSON
  list [--status STATUS] [--agent AGENT]
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rt_db import connect, generate_id


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_create(args, conn=None):
    """Create a new job.

    If no dependencies are provided the job starts as 'ready'.
    If --depends-on IDs are provided the job starts as 'pending' and
    rt_job_deps rows are inserted.
    """
    _owns_conn = conn is None
    if _owns_conn:
        conn = connect()

    try:
        job_id = generate_id()
        has_deps = bool(args.depends_on)
        status = 'pending' if has_deps else 'ready'
        payload = args.payload if args.payload else '{}'
        priority = args.priority if hasattr(args, 'priority') and args.priority is not None else 0

        conn.execute(
            "INSERT INTO rt_jobs (id, agent_id, title, status, priority, payload) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (job_id, args.agent, args.title, status, priority, payload),
        )

        if has_deps:
            for dep_id in args.depends_on:
                conn.execute(
                    "INSERT INTO rt_job_deps (job_id, depends_on_id, status) VALUES (?, ?, 'pending')",
                    (job_id, dep_id),
                )

        conn.execute(
            "INSERT INTO rt_events (id, job_id, event_type, payload) VALUES (?, ?, 'job.created', ?)",
            (generate_id(), job_id, json.dumps({'agent': args.agent, 'title': args.title})),
        )

        conn.commit()
        print(f"job_id={job_id} status={status}")
        return job_id
    finally:
        if _owns_conn:
            conn.close()


def cmd_status(args, conn=None):
    """Show status for a single job (if job_id given) or all active jobs."""
    _owns_conn = conn is None
    if _owns_conn:
        conn = connect()

    try:
        if getattr(args, 'job_id', None):
            job = conn.execute(
                "SELECT * FROM rt_jobs WHERE id = ?", (args.job_id,)
            ).fetchone()
            if not job:
                print(f"Job not found: {args.job_id}")
                return

            print(f"title:     {job['title']}")
            print(f"status:    {job['status']}")
            print(f"agent:     {job['agent_id']}")
            print(f"priority:  {job['priority']}")
            print(f"retries:   {job['retry_count']}/{job['max_retries']}")
            print(f"created:   {job['created_at']}")

            runs = conn.execute(
                "SELECT id, status, started_at, finished_at FROM rt_runs WHERE job_id = ? ORDER BY created_at",
                (args.job_id,),
            ).fetchall()
            if runs:
                print("runs:")
                for r in runs:
                    print(f"  {r['id'][:8]}  {r['status']}  started={r['started_at']}  finished={r['finished_at']}")

            deps = conn.execute(
                "SELECT depends_on_id, status FROM rt_job_deps WHERE job_id = ?",
                (args.job_id,),
            ).fetchall()
            if deps:
                print("deps:")
                for d in deps:
                    print(f"  {d['depends_on_id'][:8]}  {d['status']}")
        else:
            jobs = conn.execute(
                "SELECT id, agent_id, title, status, priority "
                "FROM rt_jobs "
                "WHERE status NOT IN ('completed', 'failed') "
                "ORDER BY priority, created_at"
            ).fetchall()

            if not jobs:
                print("No active jobs.")
                return

            header = f"{'ID':10}  {'AGENT':8}  {'STATUS':10}  {'PRI':3}  TITLE"
            print(header)
            print("-" * len(header))
            for j in jobs:
                print(f"{j['id'][:8]:10}  {j['agent_id']:8}  {j['status']:10}  {j['priority']:3}  {j['title']}")
    finally:
        if _owns_conn:
            conn.close()


def cmd_deps(args, conn=None):
    """Add a dependency: job_id depends on args.on."""
    _owns_conn = conn is None
    if _owns_conn:
        conn = connect()

    try:
        conn.execute(
            "INSERT INTO rt_job_deps (job_id, depends_on_id, status) VALUES (?, ?, 'pending')",
            (args.job_id, args.on),
        )
        conn.commit()
        print(f"dep added: {args.job_id[:8]} depends on {args.on[:8]}")
    finally:
        if _owns_conn:
            conn.close()


def cmd_resolve(args, conn=None):
    """Resolve a run dep: set status='resolved' for the given run_dep_id."""
    _owns_conn = conn is None
    if _owns_conn:
        conn = connect()

    try:
        conn.execute(
            "UPDATE rt_run_deps SET status='resolved', resolved_at=datetime('now'), result=? "
            "WHERE id=? AND status='pending'",
            (args.result, args.run_dep_id),
        )
        conn.commit()
        changes = conn.execute("SELECT changes()").fetchone()[0]
        if changes == 0:
            print(f"run dep not found or already resolved: {args.run_dep_id}")
        else:
            print(f"run dep resolved: {args.run_dep_id[:8]}")
    finally:
        if _owns_conn:
            conn.close()


def cmd_tree(args, conn=None):
    """Show delegation tree for a job."""
    _owns_conn = conn is None
    if _owns_conn:
        conn = connect()

    try:
        def print_tree(job_id, depth=0):
            job = conn.execute("SELECT * FROM rt_jobs WHERE id = ?", (job_id,)).fetchone()
            if not job:
                return
            indent = "  " * depth
            marker = "+" if depth > 0 else "*"
            print(f"{indent}{marker} [{job['status']:>9}] {job['id'][:8]}... {job['agent_id']:>6} | {job['title']}")
            children = conn.execute(
                "SELECT id FROM rt_jobs WHERE parent_job_id = ? ORDER BY created_at",
                (job_id,)
            ).fetchall()
            for child in children:
                print_tree(child['id'], depth + 1)

        print_tree(args.job_id)
    finally:
        if _owns_conn:
            conn.close()


def cmd_list(args, conn=None):
    """List jobs, optionally filtered by status and/or agent."""
    _owns_conn = conn is None
    if _owns_conn:
        conn = connect()

    try:
        filters = []
        params = []
        if getattr(args, 'status', None):
            filters.append("status = ?")
            params.append(args.status)
        if getattr(args, 'agent', None):
            filters.append("agent_id = ?")
            params.append(args.agent)

        where = ("WHERE " + " AND ".join(filters)) if filters else ""
        jobs = conn.execute(
            f"SELECT id, agent_id, title, status, priority FROM rt_jobs {where} ORDER BY priority, created_at",
            params,
        ).fetchall()

        if not jobs:
            print("No jobs found.")
            return

        header = f"{'ID':10}  {'AGENT':8}  {'STATUS':10}  {'PRI':3}  TITLE"
        print(header)
        print("-" * len(header))
        for j in jobs:
            print(f"{j['id'][:8]:10}  {j['agent_id']:8}  {j['status']:10}  {j['priority']:3}  {j['title']}")
    finally:
        if _owns_conn:
            conn.close()


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        prog='hydra rt',
        description='HYDRA Runtime Engine CLI',
    )
    sub = parser.add_subparsers(dest='command', required=True)

    # create
    p_create = sub.add_parser('create', help='Create a new job')
    p_create.add_argument('agent', help='Agent ID (e.g. forge, milo)')
    p_create.add_argument('title', help='Job title')
    p_create.add_argument('--payload', help='JSON payload string', default=None)
    p_create.add_argument('--priority', type=int, default=0, help='Priority (0=normal, 1=high)')
    p_create.add_argument('--depends-on', nargs='+', dest='depends_on', metavar='JOB_ID',
                          help='Job IDs this job depends on')

    # status
    p_status = sub.add_parser('status', help='Show job status')
    p_status.add_argument('job_id', nargs='?', default=None, help='Job ID (omit to list all active)')

    # deps
    p_deps = sub.add_parser('deps', help='Add a dependency between jobs')
    p_deps.add_argument('job_id', help='Job that will depend on another')
    p_deps.add_argument('--on', required=True, metavar='OTHER_JOB_ID', help='Job ID to depend on')

    # resolve
    p_resolve = sub.add_parser('resolve', help='Resolve a run dependency')
    p_resolve.add_argument('run_dep_id', help='rt_run_deps row ID')
    p_resolve.add_argument('--result', required=True, help='Result JSON string')

    # list
    p_list = sub.add_parser('list', help='List jobs')
    p_list.add_argument('--status', default=None, help='Filter by status')
    p_list.add_argument('--agent', default=None, help='Filter by agent ID')

    # tree
    p_tree = sub.add_parser('tree', help='Show delegation tree for a job')
    p_tree.add_argument('job_id', help='Root job ID to display')

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    dispatch = {
        'create': cmd_create,
        'status': cmd_status,
        'deps': cmd_deps,
        'resolve': cmd_resolve,
        'list': cmd_list,
        'tree': cmd_tree,
    }
    dispatch[args.command](args)


if __name__ == '__main__':
    main()
