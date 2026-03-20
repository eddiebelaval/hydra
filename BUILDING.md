# BUILDING

*The build log for HYDRA. What shipped, why it was built, and what we learned.*

Last updated: 2026-03-20

---

## Phase 1: The Nervous System (Feb 5-6, 2026)

### What shipped
23 launchd jobs, SQLite coordination database, 4-agent squad (MILO + 3 free-tier specialists), Telegram two-way communication, daily standup/briefing pipeline.

### Why
Eddie needed an always-on system to coordinate work across multiple products without manually checking each one. The thesis: premium AI for coordination, free models for execution, shell scripts for scheduling.

### Architecture decisions
- **launchd over cron:** Native macOS, survives reboots, per-job logging.
- **SQLite over Postgres:** No hosted dependency. Everything local to the Mac Studio.
- **Pipe-delimited strings over associative arrays:** Bash 3.2 compatibility (macOS constraint).
- **Telegram over Slack:** Eddie's phone is always with him. Telegram bots are trivial to set up.

---

## Phase 2: CTO Voice (Feb 7, 2026)

### What shipped
MILO answers deep technical questions about the entire id8Labs stack. TECHNICAL_BRAIN.md (~880 lines) injected as Claude Sonnet system prompt. Three-file extension pattern established.

### Why
MILO could route tasks but couldn't answer "how does the Director/Builder pattern work?" Context stuffing beats RAG for corpora under ~30 documents.

### Architecture decisions
- **Context stuffing over vector DB:** Simpler, faster, no infrastructure. TECHNICAL_BRAIN.md fits in one Sonnet call.
- **Three-file extension pattern:** Parser + handler + dispatch case. Every new capability follows this pattern.

---

## Phase 3: Auto-Updating Brain (Feb 7, 2026)

### What shipped
brain-updater.sh scans repos daily at 6 AM, Haiku summarizes git activity, updates bounded section in TECHNICAL_BRAIN.md. State tracked via SHA in JSON.

### Why
TECHNICAL_BRAIN.md was going stale within days. The CTO voice needs current data to be useful.

---

## Phase 4: Observational Memory (Feb 11, 2026)

### What shipped
Three-tier memory pipeline: Observer (15-min, Haiku), Reflector (daily, Sonnet), observations rendered to markdown. Event buffer from Telegram listener feeds observer.

### Why
HYDRA could coordinate in real-time but had no memory of patterns. The observer watches; the reflector finds meaning.

### Architecture decisions
- **Observations table over flat files:** Queryable, timestamped, compactable.
- **Bounded sections in TECHNICAL_BRAIN.md:** Observer and reflector write to their own marked regions. Manual content is never touched.

---

## Phase 5: System Soul + Goals (Feb 14, 2026)

### What shipped
SOUL.md (system identity), GOALS.md (Q1 goals with 3 auto-updated bounded sections), goals-updater.sh (daily 6:05 AM, pure bash). CTO brain now loads all 4 knowledge docs.

### Why
MILO needed values and direction, not just technical knowledge.

---

## Phase 6: Morning Planner + Evening Review (Feb 14, 2026)

### What shipped
Morning planner (8 AM): Haiku suggests 3 priorities from goals/observations/stale tasks. Eddie replies via Telegram. Evening review (8 PM): "How'd it go?" check-in with priority statuses. Conversation threads table for stateful multi-turn Telegram flows.

### Why
The briefing reported what happened. The planner helps decide what should happen. The review closes the loop.

---

## Phase 7: System Heartbeat (Feb 14, 2026)

### What shipped
30-min health checks (5 probes: launchd, db integrity, disk, event buffer, API ping). Health summary in briefings. Alert logic with rate limiting.

### Why
When HYDRA breaks silently, Eddie finds out hours later. Heartbeat makes failures loud.

---

## Phase 8: Memory Guard (Feb 20, 2026)

### What shipped
60-second vm_stat monitoring. Three tiers: WARNING (75%), CRITICAL (85%, auto-kill Codex + stale node), EMERGENCY (92%, full kill sequence). Protected processes list.

### Why
Feb 19 watchdog reset caused by Codex Helper (2GB) + node (886MB) exhausting 36GB RAM. The guard prevents recurrence.

---

## Phase 9: Wellness and Boundaries (Feb 24, 2026)

### What shipped
Event-driven morning flow (gym checkpoint -> gym proof -> breakfast -> planner -> briefing). Weekday hydration/meal/movement schedule. 10 PM hard stop. Weekend mode ("No terminal today"). Photo handling for gym proof.

### Why
Eddie's chosen health boundaries need enforcement, not reminders. The system gates terminal access behind physical activity completion.

---

## Phase 10: Agent Board (Mar 10, 2026)

### What shipped
SQLite-backed message board with 6 channels (research, builds, health, coordination, ideas, revenue). Threading via parent_id. Observer auto-posts CRITICAL observations. Morning planner reads overnight board posts as Haiku context.

### Why
Hub-and-spoke coordination (everything through Eddie) doesn't scale. The board enables lateral agent coordination: agents post findings, other agents read them.

---

## Phase 11: Mission Control Integration + Shared Config (Mar 18, 2026)

### What shipped
- **repos.sh:** Single source of truth for all monitored repos. Three-field format (Name|Path|MCSlug). Shared `parse_repo()`, `push_mc_signals()`, and `MC_CLI` path. Sourced by brain-updater, evening-review, morning-planner, and observer.
- **Brain-updater -> MC:** Pushes heartbeat signals per-product with cached commit data (no double scan). Auto-purges expired signals daily.
- **Morning planner <- MC:** Reads active MC signals as Haiku context for priority suggestions. Also reads git activity from TECHNICAL_BRAIN.md.
- **Evening review -> MC:** Pushes daily observation signals per-product with cached commit data. Shows "What shipped today" in Telegram prompt.
- **Daily briefing:** Telegram message now includes full activity bullets instead of just project names.
- **Repo list expanded:** 6 repos -> 12 repos (added Rune, Lexicon, DeepStack TV, Consciousness, Claude Code Sounds, LobeHub Local, Speak2, Mission Control; removed dormant Pause, ID8Composer).
- **Observer repo list fixed:** Was stale at 6 repos, now sources shared config.
- **TRIAD docs created:** VISION.md, SPEC.md, BUILDING.md for Mission Control ingestion.

### Why
MC is central command. Everything flows through it. HYDRA's reports were disconnected from live repo activity (brain-updater worked but downstream reports stripped the data). The shared config eliminates the #1 maintenance risk: repo lists diverging across files.

### Architecture decisions
- **Three-field format over case statement:** Co-locates slug mapping with repo definition. Adding a repo is one line in one file.
- **Commit cache via temp dir:** Brain-updater and evening-review cache commit data during the first scan, reuse for MC signal push. Eliminates 12 redundant git log calls per run.
- **Push over pull for MC:** HYDRA pushes signals to MC rather than MC polling HYDRA. Simpler, works with MC's existing signals store.

---

## Heal: Documentation + State Clarification (Mar 20, 2026)

### What shipped
- **README.md:** Full installation guide covering secrets, database init, repo config, agent config, launchd setup, and testing. Architecture diagram, daily automation flow table, directory structure reference, security notes, and cost breakdown.
- **agents.yaml.example:** Annotated example agent config with inline documentation for all fields, task routing rules, and cost limits.
- **SPEC.md:** MC integration capability row split into push and read to accurately reflect what's built. Added repos.sh shared config note.
- **VISION.md:** MC Integration pillar (Pillar 7) expanded with explicit shipped/not-yet-implemented breakdown for the three missing pieces (bi-directional Telegram bridge, MC-driven priority suggestions, centralized signal routing). Open Source Release pillar (Pillar 8) updated from UNREALIZED to PARTIAL now that docs and example configs exist.
- **Secret redaction verified:** All API keys live in gitignored `config/*.env` files. No secrets found in tracked files. telegram.env.example uses placeholder values.

### Why
Two blockers identified: (1) MC Integration documented as PARTIAL but the gap between shipped and missing wasn't specific enough to plan next steps. (2) Open Source Release blocked by missing documentation. This heal session addresses the documentation gap directly and clarifies the MC Integration gap so the next session can target a specific slice.

### What's still needed for MC Integration
The three missing pieces are independent features, each requiring work on both the HYDRA and Mission Control sides:
1. **Bi-directional Telegram bridge:** MC needs an endpoint or webhook that triggers HYDRA's Telegram bot to send messages. HYDRA needs a handler for MC-originated alerts.
2. **MC-driven priority suggestions:** MC needs a derived-signals engine that analyzes cross-product patterns and generates priority recommendations. HYDRA's morning planner would read these instead of (or in addition to) raw signals.
3. **Centralized signal routing:** Requires MC to become the canonical state store, with HYDRA reading from MC rather than maintaining parallel SQLite state for observations and health data.
