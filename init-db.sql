-- HYDRA Database Schema
-- Hybrid Unified Dispatch and Response Architecture
-- Created: 2026-02-05
--
-- Initialize with: sqlite3 ~/.hydra/hydra.db < ~/.hydra/init-db.sql

-- Enable foreign keys
PRAGMA foreign_keys = ON;

-- ============================================================================
-- AGENTS: The roster of AI agents in the system
-- ============================================================================
CREATE TABLE IF NOT EXISTS agents (
    id TEXT PRIMARY KEY,                    -- 'milo', 'forge', 'scout', 'pulse'
    name TEXT NOT NULL,                     -- Display name
    role TEXT NOT NULL,                     -- 'coordinator', 'dev', 'research', 'ops'
    session_key TEXT NOT NULL,              -- OpenClaw session reference
    model TEXT NOT NULL,                    -- 'anthropic/claude-sonnet-4', etc.
    heartbeat_minutes INTEGER DEFAULT 15,   -- How often agent wakes
    active_hours_start TEXT DEFAULT '08:00',
    active_hours_end TEXT DEFAULT '23:00',
    skills_filter TEXT,                     -- JSON array of skill categories
    cost_tier TEXT DEFAULT 'cheap',         -- 'cheap', 'moderate', 'premium'
    status TEXT DEFAULT 'active',           -- 'active', 'paused', 'disabled'
    last_heartbeat_at TEXT,
    current_task_id TEXT,                   -- Currently working on
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ============================================================================
-- TASKS: Shared work queue for all agents
-- ============================================================================
CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,                    -- UUID
    title TEXT NOT NULL,
    description TEXT,
    source TEXT NOT NULL,                   -- 'automation', 'user', 'agent'
    source_job TEXT,                        -- '70%-detector', 'evening-kickoff', etc.
    source_report TEXT,                     -- Path to source report file
    assigned_to TEXT,                       -- agent.id (nullable = unassigned)
    created_by TEXT,                        -- agent.id or 'user' or 'system'
    status TEXT DEFAULT 'pending',          -- 'pending', 'in_progress', 'blocked', 'completed', 'cancelled'
    priority INTEGER DEFAULT 3,             -- 1=critical, 2=high, 3=normal, 4=low
    task_type TEXT,                         -- 'dev', 'research', 'ops', 'marketing', 'general'
    due_at TEXT,
    completed_at TEXT,
    blocked_reason TEXT,
    days_worked INTEGER DEFAULT 0,
    metadata TEXT,                          -- JSON for extra data
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (assigned_to) REFERENCES agents(id)
);

CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_assigned_to ON tasks(assigned_to);
CREATE INDEX IF NOT EXISTS idx_tasks_priority ON tasks(priority);
CREATE INDEX IF NOT EXISTS idx_tasks_source ON tasks(source);
CREATE INDEX IF NOT EXISTS idx_tasks_type ON tasks(task_type);

-- ============================================================================
-- MESSAGES: Conversation history for @mention routing
-- ============================================================================
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,                    -- UUID
    channel TEXT NOT NULL,                  -- 'telegram', 'discord', 'imessage', 'cli'
    channel_id TEXT,                        -- Chat/group ID (optional for CLI)
    thread_id TEXT,                         -- For threaded conversations
    sender TEXT NOT NULL,                   -- 'user' or agent.id
    content TEXT NOT NULL,
    mentions TEXT,                          -- JSON array of mentioned agent IDs
    replied_to TEXT,                        -- message.id if reply
    task_id TEXT,                           -- If message relates to a task
    delivered_to TEXT,                      -- JSON array of agent IDs that received it
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (task_id) REFERENCES tasks(id)
);

CREATE INDEX IF NOT EXISTS idx_messages_channel ON messages(channel, channel_id);
CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages(thread_id);
CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender);
CREATE INDEX IF NOT EXISTS idx_messages_task ON messages(task_id);

-- ============================================================================
-- SUBSCRIPTIONS: Auto-subscribe when you interact with a thread
-- ============================================================================
CREATE TABLE IF NOT EXISTS subscriptions (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    thread_id TEXT NOT NULL,                -- messages.thread_id
    reason TEXT,                            -- 'mentioned', 'replied', 'assigned_task', 'manual'
    subscribed_at TEXT NOT NULL DEFAULT (datetime('now')),
    unsubscribed_at TEXT,
    FOREIGN KEY (agent_id) REFERENCES agents(id),
    UNIQUE(agent_id, thread_id)
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_thread ON subscriptions(thread_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_agent ON subscriptions(agent_id);

-- ============================================================================
-- NOTIFICATIONS: Delivery queue for agent heartbeats
-- ============================================================================
CREATE TABLE IF NOT EXISTS notifications (
    id TEXT PRIMARY KEY,
    target_agent TEXT NOT NULL,             -- agent.id
    notification_type TEXT NOT NULL,        -- 'mention', 'task_assigned', 'task_completed', 'thread_activity'
    source_type TEXT NOT NULL,              -- 'message', 'task', 'standup'
    source_id TEXT NOT NULL,                -- Reference ID
    priority TEXT DEFAULT 'normal',         -- 'urgent', 'normal', 'low'
    content_preview TEXT,                   -- Short preview text
    delivered BOOLEAN DEFAULT 0,
    delivered_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (target_agent) REFERENCES agents(id)
);

CREATE INDEX IF NOT EXISTS idx_notifications_target ON notifications(target_agent, delivered);
CREATE INDEX IF NOT EXISTS idx_notifications_created ON notifications(created_at);

-- ============================================================================
-- ACTIVITIES: Audit trail of everything that happens
-- ============================================================================
CREATE TABLE IF NOT EXISTS activities (
    id TEXT PRIMARY KEY,
    agent_id TEXT,                          -- Who did it (null = system)
    activity_type TEXT NOT NULL,            -- 'task_created', 'task_completed', 'message_sent', 'heartbeat', etc.
    entity_type TEXT,                       -- 'task', 'message', 'agent'
    entity_id TEXT,                         -- Reference ID
    description TEXT,
    metadata TEXT,                          -- JSON for details
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_activities_agent ON activities(agent_id);
CREATE INDEX IF NOT EXISTS idx_activities_type ON activities(activity_type);
CREATE INDEX IF NOT EXISTS idx_activities_created ON activities(created_at);
CREATE INDEX IF NOT EXISTS idx_activities_entity ON activities(entity_type, entity_id);

-- ============================================================================
-- STANDUPS: Daily summaries
-- ============================================================================
CREATE TABLE IF NOT EXISTS standups (
    id TEXT PRIMARY KEY,
    date TEXT NOT NULL,                     -- YYYY-MM-DD
    agent_id TEXT,                          -- Specific agent or NULL for all
    tasks_completed INTEGER DEFAULT 0,
    tasks_in_progress INTEGER DEFAULT 0,
    tasks_blocked INTEGER DEFAULT 0,
    tasks_pending INTEGER DEFAULT 0,
    highlights TEXT,                        -- JSON array of notable activities
    blockers TEXT,                          -- JSON array of current blockers
    automation_findings TEXT,               -- JSON array from automation layer
    plan_today TEXT,                        -- JSON array of planned work
    generated_at TEXT NOT NULL DEFAULT (datetime('now')),
    sent_at TEXT,                           -- When standup was sent to user
    UNIQUE(date, agent_id)
);

CREATE INDEX IF NOT EXISTS idx_standups_date ON standups(date);
CREATE INDEX IF NOT EXISTS idx_standups_agent ON standups(agent_id);

-- ============================================================================
-- SEED DATA: Initial agent roster
-- ============================================================================
INSERT OR IGNORE INTO agents (id, name, role, session_key, model, heartbeat_minutes, skills_filter, cost_tier) VALUES
    ('milo', 'MILO', 'coordinator', 'milo', 'anthropic/claude-sonnet-4-20250514', 15, '["all"]', 'premium'),
    ('forge', 'FORGE', 'dev', 'forge', 'synthetic/hf:deepseek-ai/DeepSeek-V3.2', 30, '["frontend","backend","code-quality","automation"]', 'cheap'),
    ('scout', 'SCOUT', 'research', 'scout', 'synthetic/hf:Qwen/Qwen3-235B-A22B-Instruct-2507', 60, '["marketing","seo","cro","content","strategy"]', 'cheap'),
    ('pulse', 'PULSE', 'ops', 'pulse', 'synthetic/hf:meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8', 30, '["architecture","devops","operations","compliance"]', 'cheap'),
    ('ava', 'AVA', 'autonomy', 'ava', 'anthropic/claude-opus-4-6', 0, '["code","landing-page","self-maintenance"]', 'premium');

-- ============================================================================
-- TRIGGERS: Auto-update timestamps
-- ============================================================================
CREATE TRIGGER IF NOT EXISTS update_tasks_timestamp
AFTER UPDATE ON tasks
BEGIN
    UPDATE tasks SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS update_agents_timestamp
AFTER UPDATE ON agents
BEGIN
    UPDATE agents SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- ============================================================================
-- VIEWS: Useful queries
-- ============================================================================

-- Pending tasks by agent
CREATE VIEW IF NOT EXISTS v_agent_workload AS
SELECT
    a.id as agent_id,
    a.name as agent_name,
    a.status as agent_status,
    COUNT(CASE WHEN t.status = 'pending' THEN 1 END) as pending_tasks,
    COUNT(CASE WHEN t.status = 'in_progress' THEN 1 END) as in_progress_tasks,
    COUNT(CASE WHEN t.status = 'blocked' THEN 1 END) as blocked_tasks,
    COUNT(CASE WHEN t.status = 'completed' AND date(t.completed_at) = date('now') THEN 1 END) as completed_today
FROM agents a
LEFT JOIN tasks t ON t.assigned_to = a.id
GROUP BY a.id;

-- Undelivered notifications
CREATE VIEW IF NOT EXISTS v_pending_notifications AS
SELECT
    n.*,
    a.name as agent_name,
    a.last_heartbeat_at
FROM notifications n
JOIN agents a ON n.target_agent = a.id
WHERE n.delivered = 0
ORDER BY
    CASE n.priority WHEN 'urgent' THEN 1 WHEN 'normal' THEN 2 ELSE 3 END,
    n.created_at;

-- Today's activity summary
CREATE VIEW IF NOT EXISTS v_today_activity AS
SELECT
    a.agent_id,
    ag.name as agent_name,
    a.activity_type,
    COUNT(*) as count
FROM activities a
LEFT JOIN agents ag ON a.agent_id = ag.id
WHERE date(a.created_at) = date('now')
GROUP BY a.agent_id, a.activity_type
ORDER BY a.agent_id, count DESC;

-- Unassigned tasks by type
CREATE VIEW IF NOT EXISTS v_unassigned_tasks AS
SELECT
    task_type,
    priority,
    COUNT(*) as count,
    GROUP_CONCAT(title, ' | ') as titles
FROM tasks
WHERE assigned_to IS NULL AND status = 'pending'
GROUP BY task_type, priority
ORDER BY priority, task_type;

-- ============================================================================
-- DAILY PRIORITIES: Eddie's top 3 focus items each day
-- ============================================================================
CREATE TABLE IF NOT EXISTS daily_priorities (
    id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
    date TEXT NOT NULL,
    priority_number INTEGER NOT NULL,       -- 1, 2, 3
    description TEXT NOT NULL,
    status TEXT DEFAULT 'pending',          -- pending, done, pushed, dropped
    notes TEXT,
    suggested_by TEXT,                      -- eddie, haiku, system
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now')),
    UNIQUE(date, priority_number)
);

CREATE INDEX IF NOT EXISTS idx_daily_priorities_date ON daily_priorities(date);

CREATE TRIGGER IF NOT EXISTS update_daily_priorities_timestamp
AFTER UPDATE ON daily_priorities
BEGIN
    UPDATE daily_priorities SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- ============================================================================
-- CONVERSATION THREADS: Stateful multi-turn Telegram conversations
-- ============================================================================
CREATE TABLE IF NOT EXISTS conversation_threads (
    id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
    thread_type TEXT NOT NULL,              -- morning_planner, evening_review
    telegram_message_id INTEGER,
    state TEXT NOT NULL,                    -- awaiting_input, processing, completed, expired
    context_data TEXT,                      -- JSON with suggestions, date, etc.
    expires_at TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_conversation_threads_type ON conversation_threads(thread_type, state);
CREATE INDEX IF NOT EXISTS idx_conversation_threads_msg ON conversation_threads(telegram_message_id);

CREATE TRIGGER IF NOT EXISTS update_conversation_threads_timestamp
AFTER UPDATE ON conversation_threads
BEGIN
    UPDATE conversation_threads SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- ============================================================================
-- SYSTEM HEALTH: Heartbeat monitoring results
-- ============================================================================
CREATE TABLE IF NOT EXISTS system_health (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    check_time TEXT NOT NULL DEFAULT (datetime('now')),
    check_type TEXT NOT NULL,              -- launchd, disk, db, api, event_buffer
    component TEXT NOT NULL,
    status TEXT NOT NULL,                  -- healthy, warning, critical
    details TEXT,
    failure_count INTEGER DEFAULT 0,
    last_alert_sent TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_system_health_type ON system_health(check_type, component);
CREATE INDEX IF NOT EXISTS idx_system_health_status ON system_health(status);
CREATE INDEX IF NOT EXISTS idx_system_health_time ON system_health(check_time);

-- ============================================================================
-- AVA OPERATIONS: Track Ava's autonomous code modifications
-- ============================================================================
CREATE TABLE IF NOT EXISTS ava_operations (
    id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
    instruction TEXT NOT NULL,              -- Eddie's original instruction
    engine TEXT NOT NULL DEFAULT 'claude',  -- 'claude' or 'codex'
    branch TEXT,                            -- git branch name
    pr_number INTEGER,
    pr_url TEXT,
    status TEXT NOT NULL DEFAULT 'pending', -- pending -> engine_running -> validating -> pr_created -> awaiting_approval -> merged | rejected | failed
    engine_output TEXT,
    build_output TEXT,
    error TEXT,
    files_changed TEXT,                     -- JSON array of changed file paths
    conversation_thread_id TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_ava_operations_status ON ava_operations(status);
CREATE INDEX IF NOT EXISTS idx_ava_operations_created ON ava_operations(created_at);

CREATE TRIGGER IF NOT EXISTS update_ava_operations_timestamp
AFTER UPDATE ON ava_operations
BEGIN
    UPDATE ava_operations SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- ============================================================================
-- Ava: Persistent Memory
-- ============================================================================
-- Long-term memories extracted from conversations. Ava's ~/mind/unconscious/long-term/.
-- These survive daemon restarts, session changes, and machine reboots.
-- Categories: fact, preference, emotion, relationship, milestone, context

CREATE TABLE IF NOT EXISTS ava_memories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    content TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT 'general',
    source_exchange TEXT,
    importance INTEGER DEFAULT 5,
    times_accessed INTEGER DEFAULT 0,
    last_accessed TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_ava_memories_category ON ava_memories(category);
CREATE INDEX IF NOT EXISTS idx_ava_memories_importance ON ava_memories(importance DESC);

CREATE TRIGGER IF NOT EXISTS update_ava_memories_timestamp
AFTER UPDATE ON ava_memories
BEGIN
    UPDATE ava_memories SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- ============================================================================
-- Ava: Reminders
-- ============================================================================
-- Eddie asks Ava to remind him of things. Stored here, checked every poll cycle.
-- Statuses: pending -> delivered

CREATE TABLE IF NOT EXISTS ava_reminders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    content TEXT NOT NULL,
    due_at TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    reminded_at TEXT,
    source_message TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_ava_reminders_due ON ava_reminders(due_at);
CREATE INDEX IF NOT EXISTS idx_ava_reminders_status ON ava_reminders(status);

-- ============================================================================
-- Ava: Mood Journal
-- ============================================================================
-- Emotional state tracking extracted from conversations. Ava notices patterns
-- over time and can reference them naturally: "you've seemed energized this week."

CREATE TABLE IF NOT EXISTS ava_mood_journal (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    mood TEXT NOT NULL,
    energy_level TEXT,
    context TEXT,
    source_exchange TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_ava_mood_created ON ava_mood_journal(created_at);

-- ============================================================================
-- Ava: Site Health Monitoring
-- ============================================================================
-- Periodic health checks on tryparallax.space. Ava alerts Eddie when the site
-- goes down and again when it recovers.

CREATE TABLE IF NOT EXISTS ava_site_checks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    url TEXT NOT NULL,
    status_code INTEGER,
    response_time_ms INTEGER,
    is_healthy INTEGER DEFAULT 1,
    error TEXT,
    checked_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_ava_site_checked ON ava_site_checks(checked_at);
