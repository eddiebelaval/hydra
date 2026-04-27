-- Milo Telegram Personal Assistant - Database Tables
-- Migration: 2026-04-03
-- All tables in hydra.db with milo_ prefix

-- ============================================================================
-- CONVERSATIONS: Every message turn for full history reconstruction
-- ============================================================================
CREATE TABLE IF NOT EXISTS milo_conversations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'tool_use', 'tool_result')),
    content TEXT NOT NULL,
    tool_name TEXT,
    tool_input TEXT,
    token_count INTEGER,
    session_id TEXT,
    telegram_message_id INTEGER,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_milo_conv_session ON milo_conversations(session_id);
CREATE INDEX IF NOT EXISTS idx_milo_conv_created ON milo_conversations(created_at);

-- ============================================================================
-- CONVERSATION SUMMARIES: Compressed history beyond rolling window
-- ============================================================================
CREATE TABLE IF NOT EXISTS milo_conversation_summaries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    summary TEXT NOT NULL,
    turn_range_start INTEGER NOT NULL,
    turn_range_end INTEGER NOT NULL,
    turn_count INTEGER NOT NULL,
    key_topics TEXT,
    key_decisions TEXT,
    emotional_tone TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_milo_summaries_created ON milo_conversation_summaries(created_at);

-- ============================================================================
-- PERSISTENT MEMORIES: Facts, preferences, context about Eddie
-- ============================================================================
CREATE TABLE IF NOT EXISTS milo_memories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    content TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT 'general',
    source_summary TEXT,
    importance INTEGER DEFAULT 5 CHECK (importance >= 1 AND importance <= 10),
    times_accessed INTEGER DEFAULT 0,
    last_accessed TEXT,
    superseded_by INTEGER,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_milo_mem_category ON milo_memories(category);
CREATE INDEX IF NOT EXISTS idx_milo_mem_importance ON milo_memories(importance DESC);

CREATE TRIGGER IF NOT EXISTS update_milo_memories_timestamp
AFTER UPDATE ON milo_memories
BEGIN
    UPDATE milo_memories SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- ============================================================================
-- STRATEGIES: Approaches, decisions, reasoning linked to goals
-- ============================================================================
CREATE TABLE IF NOT EXISTS milo_strategies (
    id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    goal_id TEXT,
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'revised', 'archived', 'abandoned')),
    revised_from TEXT,
    key_assumptions TEXT,
    evidence TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (goal_id) REFERENCES goals(id)
);

CREATE INDEX IF NOT EXISTS idx_milo_strat_status ON milo_strategies(status);
CREATE INDEX IF NOT EXISTS idx_milo_strat_goal ON milo_strategies(goal_id);

CREATE TRIGGER IF NOT EXISTS update_milo_strategies_timestamp
AFTER UPDATE ON milo_strategies
BEGIN
    UPDATE milo_strategies SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- ============================================================================
-- EVENTS: Calendar-like awareness, reminders, deadlines
-- ============================================================================
CREATE TABLE IF NOT EXISTS milo_events (
    id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
    title TEXT NOT NULL,
    description TEXT,
    event_type TEXT DEFAULT 'event' CHECK (event_type IN ('event', 'reminder', 'deadline', 'recurring')),
    starts_at TEXT,
    ends_at TEXT,
    all_day INTEGER DEFAULT 0,
    recurrence_rule TEXT,
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'completed', 'cancelled', 'snoozed')),
    reminded_at TEXT,
    goal_id TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (goal_id) REFERENCES goals(id)
);

CREATE INDEX IF NOT EXISTS idx_milo_events_starts ON milo_events(starts_at);
CREATE INDEX IF NOT EXISTS idx_milo_events_status ON milo_events(status);
CREATE INDEX IF NOT EXISTS idx_milo_events_type ON milo_events(event_type);

CREATE TRIGGER IF NOT EXISTS update_milo_events_timestamp
AFTER UPDATE ON milo_events
BEGIN
    UPDATE milo_events SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- ============================================================================
-- MOOD JOURNAL: Eddie's emotional state over time
-- ============================================================================
CREATE TABLE IF NOT EXISTS milo_mood_journal (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    mood TEXT NOT NULL,
    energy_level TEXT,
    context TEXT,
    source_turn_id INTEGER,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_milo_mood_created ON milo_mood_journal(created_at);
