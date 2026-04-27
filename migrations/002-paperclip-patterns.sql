-- HYDRA Migration 002: Paperclip-Inspired Patterns
-- Smart heartbeat scheduling, adapter contracts, auto-cost capture
-- Reference: github.com/paperclipai/paperclip (MIT)
-- Applied: 2026-03-10
--
-- Run: sqlite3 ~/.hydra/hydra.db < ~/.hydra/migrations/002-paperclip-patterns.sql

-- ============================================================================
-- AGENTS: Add budget + adapter columns
-- Inspired by Paperclip's agents table (budgetMonthlyCents, spentMonthlyCents, adapterType)
-- ============================================================================

-- Per-agent monthly budget in cents (0 = unlimited)
ALTER TABLE agents ADD COLUMN budget_monthly_cents INTEGER DEFAULT 0;

-- Running monthly spend in cents (reset on 1st of month)
ALTER TABLE agents ADD COLUMN spent_monthly_cents INTEGER DEFAULT 0;

-- Adapter type: how to execute this agent ('claude_local', 'codex_local', 'hydra_daemon', 'http_webhook')
ALTER TABLE agents ADD COLUMN adapter_type TEXT DEFAULT 'hydra_daemon';

-- Adapter config as JSON (cwd, model overrides, env vars, timeout, etc.)
ALTER TABLE agents ADD COLUMN adapter_config TEXT DEFAULT '{}';

-- Last month the spend was reset (YYYY-MM format)
ALTER TABLE agents ADD COLUMN spend_reset_month TEXT DEFAULT '';

-- ============================================================================
-- COST_EVENTS: Per-action cost tracking (replaces coarse daily cost_records)
-- Inspired by Paperclip's costEvents table — granular, per-agent, per-task
-- ============================================================================

CREATE TABLE IF NOT EXISTS cost_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_id TEXT NOT NULL REFERENCES agents(id),
    task_id TEXT REFERENCES tasks(id),          -- nullable (overhead costs)
    cost_cents INTEGER NOT NULL DEFAULT 0,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    cached_tokens INTEGER DEFAULT 0,
    model TEXT,                                  -- 'claude-opus-4-6', etc.
    billing_type TEXT DEFAULT 'api',             -- 'api', 'subscription', 'free'
    source TEXT DEFAULT 'auto',                  -- 'auto', 'manual', 'heartbeat'
    details TEXT DEFAULT '',                     -- human-readable note
    occurred_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_cost_events_agent ON cost_events(agent_id);
CREATE INDEX IF NOT EXISTS idx_cost_events_task ON cost_events(task_id);
CREATE INDEX IF NOT EXISTS idx_cost_events_date ON cost_events(occurred_at);

-- ============================================================================
-- TASK_RUNS: Execution log for each agent<->task attempt
-- Inspired by Paperclip's heartbeatRuns table — tracks each wake cycle
-- ============================================================================

CREATE TABLE IF NOT EXISTS task_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_id TEXT NOT NULL REFERENCES agents(id),
    task_id TEXT NOT NULL REFERENCES tasks(id),
    status TEXT DEFAULT 'running',               -- 'running', 'completed', 'failed', 'timeout'
    exit_code INTEGER,
    error_message TEXT,
    cost_cents INTEGER DEFAULT 0,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    model TEXT,
    started_at TEXT DEFAULT (datetime('now')),
    finished_at TEXT,
    duration_sec INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_task_runs_agent ON task_runs(agent_id);
CREATE INDEX IF NOT EXISTS idx_task_runs_task ON task_runs(task_id);
CREATE INDEX IF NOT EXISTS idx_task_runs_status ON task_runs(status);

-- ============================================================================
-- VIEWS: Operational dashboards
-- ============================================================================

-- Agent budget utilization view
CREATE VIEW IF NOT EXISTS v_agent_budgets AS
SELECT
    a.id,
    a.name,
    a.adapter_type,
    a.budget_monthly_cents,
    a.spent_monthly_cents,
    CASE
        WHEN a.budget_monthly_cents = 0 THEN 0
        ELSE ROUND(CAST(a.spent_monthly_cents AS REAL) / a.budget_monthly_cents * 100, 1)
    END AS utilization_pct,
    CASE
        WHEN a.budget_monthly_cents > 0 AND a.spent_monthly_cents >= a.budget_monthly_cents THEN 'over_budget'
        WHEN a.budget_monthly_cents > 0 AND a.spent_monthly_cents >= a.budget_monthly_cents * 0.8 THEN 'warning'
        ELSE 'ok'
    END AS budget_status,
    a.status,
    a.current_task_id
FROM agents a
WHERE a.status != 'disabled';

-- Recent task runs with cost
CREATE VIEW IF NOT EXISTS v_recent_runs AS
SELECT
    tr.id,
    a.name AS agent_name,
    t.title AS task_title,
    tr.status,
    tr.cost_cents,
    tr.input_tokens,
    tr.output_tokens,
    tr.duration_sec,
    tr.started_at,
    tr.finished_at
FROM task_runs tr
JOIN agents a ON tr.agent_id = a.id
JOIN tasks t ON tr.task_id = t.id
ORDER BY tr.started_at DESC
LIMIT 50;
