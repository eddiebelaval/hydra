---
last-reconciled: 2026-03-20
status: CURRENT
---

# SPEC

## Identity

HYDRA (Hybrid Unified Dispatch and Response Architecture) is a multi-agent coordination system running entirely on Eddie Belaval's Mac Studio. It uses macOS launchd for scheduling, SQLite for state, Claude Sonnet for coordination, and Claude Haiku for parsing. Communication happens via Telegram. Cost: ~$300/month.

Build stage: Stage 10 (Live + Iterate)

## System Overview

### Architecture

```
Eddie (Telegram / CLI)
    |
    v
telegram-listener.sh (long-polling, KeepAlive)
    |
    v
telegram-parse-natural.sh (Haiku NL -> command)
    |
    v
dispatch_command() -> hydra-cli.sh (ops)
                   -> ask_cto_brain() (CTO voice via Sonnet)
    |
    v
hydra.db (SQLite) + TECHNICAL_BRAIN.md (knowledge)
```

### Agent Squad

- **MILO** (Claude Sonnet 4.5) -- Coordinator. 15-min heartbeat. Premium tier.
- **FORGE** (DeepSeek V3.2 via HuggingFace) -- Dev specialist. 30-min heartbeat. Free.
- **SCOUT** (Qwen 3 235B via HuggingFace) -- Research/Marketing. 60-min heartbeat. Free.
- **PULSE** (Llama 4 Maverick via HuggingFace) -- Ops specialist. 30-min heartbeat. Free.

### Daily Automation Flow

- **6:00 AM** -- Brain updater: scan repos, Haiku summary, update TECHNICAL_BRAIN.md, push MC signals, purge expired signals
- **6:05 AM** -- Goals updater: refresh bounded sections from SQLite + observations
- **7:30 AM** -- Wellness daemon: gym checkpoint (event-driven morning flow)
- **8:00 AM** -- Morning planner: AI suggestions via Haiku (fed by goals, observations, git activity, MC signals, agent board), Telegram prompt for top 3
- **8:40 AM** -- Daily briefing: comprehensive report (priorities, activity, agents, health, signals), MacDown + Telegram
- **8:00 PM** -- Evening review: today's git activity + priority status check-in via Telegram
- **Every 15 min** -- Observer: collect events, compress via Haiku, store observations
- **Every 30 min** -- Heartbeat: 5 system health checks
- **Every 60 sec** -- Memory guard: vm_stat monitoring, auto-kill on memory pressure
- **Daily 2 AM** -- Reflector: 7-day observation consolidation via Sonnet

### Database Schema (hydra.db)

agents, tasks, messages, notifications, activities, standups, cost_records, daily_priorities, conversation_threads, observations, reflections, system_health, agent_board

### Key Files

- **Daemons:** `~/.hydra/daemons/` (20 scripts)
- **Tools:** `~/.hydra/tools/` (35 scripts)
- **Config:** `~/.hydra/config/` (telegram.env, repos.sh, agents.yaml)
- **Knowledge:** TECHNICAL_BRAIN.md, SOUL.md, GOALS.md, JOURNEY.md
- **State:** `~/.hydra/state/` (JSON state files, flag files)
- **LaunchAgents:** `~/Library/LaunchAgents/com.hydra.*.plist`

### Extension Pattern

Three files to add a capability:
1. `telegram-parse-natural.sh` -- add command type to NL parser
2. `telegram-listener.sh` -- add handler function
3. Dispatch case connecting them

### Shared Configuration

`~/.hydra/config/repos.sh` is the single source of truth for monitored repos. Three-field format: `Name|Path|MCSlug`. All daemons and tools source this file. Includes `parse_repo()`, `push_mc_signals()`, and `MC_CLI` path.

## Constraints

- **Bash 3.2:** macOS `/bin/bash` is 3.2. No associative arrays, no `readarray`, no `${var,,}`.
- **Local-only:** Everything runs on Mac Studio. No cloud infrastructure for HYDRA itself.
- **Telegram limits:** 4096 char messages, HTML parse_mode (no markdown tables).
- **Cost ceiling:** Premium model (Sonnet) for coordination only. Haiku for parsing. Free models for execution.

## Current Capabilities

| Capability | Status | Notes |
|-----------|--------|-------|
| Scheduled jobs | 23+ launchd plists | Zero-cost scheduling |
| Telegram NL control | 16 command types | Haiku + regex fallback |
| CTO brain (tech Q&A) | ~100KB context stuffing | Sonnet + 4 knowledge docs |
| Voice in/out | Deepgram + ElevenLabs | Async delivery |
| Observational memory | 15-min observer + daily reflector | Haiku + Sonnet |
| Wellness enforcement | Event-driven morning, clock-driven day | Pure bash |
| Agent board | 6 channels, threading | SQLite-backed |
| MC integration (push) | Heartbeat + observation signals | Via mc CLI, repos.sh shared config |
| MC integration (read) | Morning planner reads MC signals | Haiku context for priority suggestions |
| Memory guard | 60s vm_stat monitoring | Auto-kill on pressure |
| Health monitoring | 30-min heartbeat, 5 checks | SQLite + alerts |
