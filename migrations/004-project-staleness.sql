-- 004-project-staleness.sql
-- Tracks per-project staleness metrics for dormant project detection.
-- Used by project-staleness.sh daemon (weekly Sunday 5:30 AM)
-- and read by hydra-observer.sh for daily staleness signals.

CREATE TABLE IF NOT EXISTS project_staleness (
    repo_name TEXT PRIMARY KEY,
    repo_path TEXT NOT NULL,
    last_commit_date TEXT,
    last_commit_msg TEXT,
    days_since_commit INTEGER,
    has_vercel INTEGER DEFAULT 0,
    vercel_url TEXT,
    status TEXT DEFAULT 'active' CHECK(status IN ('active', 'stale', 'dormant', 'archived')),
    updated_at TEXT DEFAULT (datetime('now'))
);

-- active:   committed within 14 days
-- stale:    15-30 days since last commit
-- dormant:  31+ days since last commit
-- archived: manually marked, excluded from reports
