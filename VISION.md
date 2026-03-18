---
last-reconciled: 2026-03-18
status: CURRENT
---

# VISION

## Soul

HYDRA is Eddie's cognitive leverage system. It handles the repetitive, the scheduled, and the watchful so Eddie can focus on strategy and creation. It is not an assistant. It is a co-founder-grade operating layer that knows the codebase, tracks the goals, monitors the health, and speaks with Eddie's voice when asked.

## Why This Exists

A solo founder running 10+ products cannot maintain awareness of everything that matters across all of them simultaneously. Context switches destroy flow. Manual check-ins waste creative energy. Important signals get buried under noise.

HYDRA exists to be the always-on nervous system: it watches the repos, tracks the goals, enforces the boundaries, and surfaces what matters before Eddie has to ask. The design principle is cognitive leverage, not cognitive replacement. Eddie handles strategy and creation. HYDRA handles coordination and vigilance.

## Pillars

### 1. **Scheduled Coordination** -- REALIZED

23+ launchd jobs orchestrate the daily rhythm: morning planner, daily briefing, evening review, heartbeats, observer, reflector, brain-updater, goals-updater, wellness daemon, memory guard. All bash, zero cost for scheduling.

### 2. **CTO Voice** -- REALIZED

MILO answers deep technical questions about the entire id8Labs stack via Telegram. Knowledge stack: SOUL.md (identity) + TECHNICAL_BRAIN.md (how) + JOURNEY.md (why) + GOALS.md (where), all injected as Claude Sonnet system prompt. Handles text and voice input.

### 3. **Observational Memory** -- REALIZED

Three-tier memory pipeline: Observer (15-min, Haiku) collects events from Telegram, git, and system activity. Reflector (daily, Sonnet) consolidates into behavioral patterns. Brain-updater (daily) summarizes git activity. All feed TECHNICAL_BRAIN.md bounded sections.

### 4. **Two-Way Telegram Control** -- REALIZED

Full NL command interface via Telegram with two-tier parsing (Haiku primary, regex fallback). Conversation threads enable stateful multi-turn interactions. Voice transcription via Deepgram. TTS via ElevenLabs. Reply routing for planner, review, gym checkpoint flows.

### 5. **Wellness and Boundaries** -- REALIZED

Event-driven morning flow (gym gate before terminal), weekday hydration/meal/movement reminders, 10 PM hard stop, weekend mode. Enforces Eddie's chosen boundaries, not suggestions. Pure bash, zero AI cost.

### 6. **Agent Board** -- REALIZED

Lateral agent coordination via SQLite-backed message board with channels (research, builds, health, coordination, ideas, revenue). Agents post findings, other agents read them. Threading via parent_id. Replaces hub-and-spoke with mesh pattern.

### 7. **Mission Control Integration** -- PARTIAL

HYDRA pushes heartbeat and observation signals to Mission Control's signals store. Morning planner reads MC signals for context. Missing: Bi-directional Telegram bridge, MC-driven priority suggestions, centralized signal routing through MC as single source of truth.

### 8. **Open Source Release** -- UNREALIZED

Clean up scripts, write README, redact secrets, publish at github.com/eddiebelaval/hydra. Missing: Documentation, example configs, secret redaction pass, installation guide.

## Phased Vision

### Phase 1 -- Local OS (Complete)

The nervous system that runs Eddie's day: scheduling, briefings, health monitoring, Telegram control, wellness boundaries.

### Phase 2 -- Intelligence Layer (Complete)

Observational memory, behavioral pattern detection, CTO voice, goal tracking. HYDRA that not only runs the schedule but understands the patterns.

### Phase 3 -- Central Command Integration (In Progress)

Wire all HYDRA signals through Mission Control. MC becomes the single source of truth. HYDRA reads from and writes to MC. Telegram bridge for bi-directional flow.

### Phase 4 -- Open Source

Publish the system so other solo founders can run their own HYDRA.

## Anti-Vision

HYDRA must never become:

- a chatbot that tries to be friendly instead of useful
- a monitoring system that creates more noise than it eliminates
- a rigid process that fights Eddie's natural workflow instead of supporting it
- an over-engineered system that requires its own maintenance team
- a replacement for Eddie's judgment on creative and strategic decisions
