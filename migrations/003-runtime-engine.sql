-- HYDRA Migration 003: Runtime Engine
-- Durable execution with agent delegation
-- Reference: docs/superpowers/specs/2026-04-01-hydra-runtime-engine-design.md
-- Applied: 2026-04-01
--
-- Run: sqlite3 ~/.hydra/hydra.db < ~/.hydra/migrations/003-runtime-engine.sql

-- Enable WAL mode for concurrent reads during writes
PRAGMA journal_mode = WAL;

-- rt_jobs: Durable work units
CREATE TABLE IF NOT EXISTS rt_jobs (
    id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
    parent_job_id TEXT,
    agent_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    priority INTEGER NOT NULL DEFAULT 0,
    fail_fast INTEGER NOT NULL DEFAULT 0,
    title TEXT NOT NULL,
    payload TEXT NOT NULL DEFAULT '{}',
    result TEXT,
    max_retries INTEGER DEFAULT 3,
    retry_count INTEGER DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (parent_job_id) REFERENCES rt_jobs(id),
    FOREIGN KEY (agent_id) REFERENCES agents(id)
);

CREATE INDEX IF NOT EXISTS idx_rt_jobs_status ON rt_jobs(status);
CREATE INDEX IF NOT EXISTS idx_rt_jobs_agent ON rt_jobs(agent_id, status);
CREATE INDEX IF NOT EXISTS idx_rt_jobs_parent ON rt_jobs(parent_job_id);

-- rt_job_deps: Dependency graph between jobs
CREATE TABLE IF NOT EXISTS rt_job_deps (
    job_id TEXT NOT NULL,
    depends_on_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    satisfied_at TEXT,
    PRIMARY KEY (job_id, depends_on_id),
    FOREIGN KEY (job_id) REFERENCES rt_jobs(id),
    FOREIGN KEY (depends_on_id) REFERENCES rt_jobs(id)
);

CREATE INDEX IF NOT EXISTS idx_rt_job_deps_blocked ON rt_job_deps(job_id, status);
CREATE INDEX IF NOT EXISTS idx_rt_job_deps_blocking ON rt_job_deps(depends_on_id, status);

-- rt_runs: Execution attempts within a job
CREATE TABLE IF NOT EXISTS rt_runs (
    id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
    job_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    started_at TEXT,
    finished_at TEXT,
    result TEXT,
    error TEXT,
    cost_cents INTEGER DEFAULT 0,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    model TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (job_id) REFERENCES rt_jobs(id)
);

CREATE INDEX IF NOT EXISTS idx_rt_runs_job ON rt_runs(job_id);
CREATE INDEX IF NOT EXISTS idx_rt_runs_status ON rt_runs(status);

-- rt_run_claims: Ownership leases
CREATE TABLE IF NOT EXISTS rt_run_claims (
    run_id TEXT PRIMARY KEY,
    worker_id TEXT NOT NULL,
    claimed_at TEXT NOT NULL DEFAULT (datetime('now')),
    lease_ttl_sec INTEGER NOT NULL DEFAULT 300,
    last_heartbeat TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (run_id) REFERENCES rt_runs(id)
);

-- rt_run_deps: Waits (blocked outcomes per run)
CREATE TABLE IF NOT EXISTS rt_run_deps (
    id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
    run_id TEXT NOT NULL,
    wait_type TEXT NOT NULL,
    target_id TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    resolved_at TEXT,
    result TEXT,
    FOREIGN KEY (run_id) REFERENCES rt_runs(id)
);

CREATE INDEX IF NOT EXISTS idx_rt_run_deps_run ON rt_run_deps(run_id, status);
CREATE INDEX IF NOT EXISTS idx_rt_run_deps_target ON rt_run_deps(target_id);

-- rt_events: Side-effect outbox
CREATE TABLE IF NOT EXISTS rt_events (
    id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
    job_id TEXT,
    run_id TEXT,
    event_type TEXT NOT NULL,
    payload TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    delivered_at TEXT,
    FOREIGN KEY (job_id) REFERENCES rt_jobs(id),
    FOREIGN KEY (run_id) REFERENCES rt_runs(id)
);

CREATE INDEX IF NOT EXISTS idx_rt_events_undelivered ON rt_events(delivered_at) WHERE delivered_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_rt_events_type ON rt_events(event_type);

-- Auto-update timestamp trigger for rt_jobs
CREATE TRIGGER IF NOT EXISTS update_rt_jobs_timestamp
AFTER UPDATE ON rt_jobs
BEGIN
    UPDATE rt_jobs SET updated_at = datetime('now') WHERE id = NEW.id;
END;
