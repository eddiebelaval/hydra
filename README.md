# HYDRA

**Hybrid Unified Dispatch and Response Architecture**

A multi-agent coordination system that runs entirely on macOS. Uses launchd for scheduling, SQLite for state, Claude Sonnet for coordination, Claude Haiku for parsing, and Telegram for two-way communication.

Built for solo founders running multiple products who need an always-on nervous system to watch repos, track goals, enforce boundaries, and surface what matters.

## Architecture

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

## Agent Squad

| Agent | Model | Role | Heartbeat | Cost |
|-------|-------|------|-----------|------|
| MILO | Claude Sonnet 4.5 | Coordinator | 15 min | Premium |
| FORGE | DeepSeek V3.2 (HuggingFace) | Dev specialist | 30 min | Free |
| SCOUT | Qwen 3 235B (HuggingFace) | Research/Marketing | 60 min | Free |
| PULSE | Llama 4 Maverick (HuggingFace) | Ops specialist | 30 min | Free |

## Requirements

- macOS (uses launchd and Bash 3.2)
- Python 3.9+
- SQLite 3
- curl, jq
- Anthropic API key (Claude Sonnet + Haiku)
- Telegram bot token + chat ID

### Optional

- Deepgram API key (voice transcription)
- ElevenLabs API key (text-to-speech)
- HuggingFace Inference API access (free-tier agents)
- Mission Control CLI (`mc`) for cross-product signal routing

## Installation

### 1. Clone the repo

```bash
git clone https://github.com/eddiebelaval/hydra.git ~/.hydra
cd ~/.hydra
```

### 2. Configure secrets

```bash
cp config/telegram.env.example config/telegram.env
```

Edit `config/telegram.env` with your credentials:

```bash
# Required
TELEGRAM_BOT_TOKEN="your-bot-token"    # From @BotFather on Telegram
TELEGRAM_CHAT_ID="your-chat-id"        # From @userinfobot or @getmyid_bot
ANTHROPIC_API_KEY="sk-ant-..."         # From console.anthropic.com

# Optional (voice features)
DEEPGRAM_API_KEY="your-key"            # For voice transcription
ELEVENLABS_API_KEY="your-key"          # For text-to-speech responses
```

### 3. Initialize the database

```bash
sqlite3 ~/.hydra/hydra.db < init-db.sql
```

### 4. Configure monitored repos

Edit `config/repos.sh` to list your repositories:

```bash
HYDRA_REPOS=(
    "MyApp|$HOME/Development/my-app|my-app-slug"
    "Website|$HOME/Development/website|"
)
```

Format: `DisplayName|AbsolutePath|MCSlug` (MCSlug is optional, for Mission Control integration).

### 5. Configure agents

Edit `config/agents.yaml` to customize the agent squad. Each agent needs:
- `model`: API model identifier
- `heartbeat_minutes`: How often the agent wakes
- `cost_tier`: `premium` (paid API) or `free` (HuggingFace)
- `skills`: Array of capability categories for task routing

### 6. Create runtime directories

```bash
mkdir -p ~/.hydra/state ~/.hydra/logs
```

### 7. Install launchd jobs

Copy the plist templates to `~/Library/LaunchAgents/` and load them:

```bash
# Example: load the Telegram listener
cp plists/com.hydra.telegram-listener.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.hydra.telegram-listener.plist
```

Key jobs to install:
- `com.hydra.telegram-listener` -- Telegram command listener (KeepAlive)
- `com.hydra.brain-updater` -- Daily 6 AM git activity scan
- `com.hydra.morning-planner` -- Daily 8 AM priority suggestions
- `com.hydra.briefing` -- Daily 8:40 AM comprehensive briefing
- `com.hydra.evening-review` -- Daily 8 PM check-in
- `com.hydra.heartbeat` -- Every 30 min health checks
- `com.hydra.observer` -- Every 15 min event collection
- `com.hydra.memory-guard` -- Every 60 sec memory pressure monitor

### 8. Test the setup

```bash
# Verify Telegram connectivity
tools/telegram-setup.sh

# Send a test message
daemons/notify-eddie.sh info "HYDRA" "Installation complete."
```

## Directory Structure

```
~/.hydra/
  config/          # Secrets and configuration (gitignored: *.env)
    telegram.env   # API keys and bot credentials
    agents.yaml    # Agent squad configuration
    repos.sh       # Monitored repository list
  daemons/         # Long-running and scheduled scripts (20)
  tools/           # Utility scripts called by daemons (30+)
  lib/             # Shared libraries (bash + python)
  state/           # Runtime state files (gitignored)
  logs/            # Runtime logs (gitignored)
  memory/          # Observation and reflection data
  templates/       # Briefing and report templates
  TECHNICAL_BRAIN.md  # CTO knowledge base (~100KB, auto-updated)
  SOUL.md             # System identity and values
  GOALS.md            # Q1 goals with auto-updated sections
  JOURNEY.md          # Narrative build history
  hydra.db            # SQLite coordination database (gitignored)
  init-db.sql         # Database schema (source of truth)
```

## Daily Automation Flow

| Time | Job | Description |
|------|-----|-------------|
| 6:00 AM | brain-updater | Scan repos, summarize git activity, update TECHNICAL_BRAIN.md |
| 6:05 AM | goals-updater | Refresh bounded sections from SQLite + observations |
| 7:30 AM | wellness-daemon | Gym checkpoint (event-driven morning flow) |
| 8:00 AM | morning-planner | AI priority suggestions via Haiku, Telegram prompt |
| 8:40 AM | daily-briefing | Comprehensive report (priorities, activity, agents, health) |
| 8:00 PM | evening-review | "How'd it go?" check-in with priority statuses |
| Every 15m | observer | Collect events, compress via Haiku, store observations |
| Every 30m | heartbeat | 5 system health checks (launchd, db, disk, API, events) |
| Every 60s | memory-guard | vm_stat monitoring, auto-kill on memory pressure |
| 2:00 AM | reflector | 7-day observation consolidation via Sonnet |

## Adding a New Capability

Three files to add any command:

1. `tools/telegram-parse-natural.sh` -- Add command type to NL parser
2. `daemons/telegram-listener.sh` -- Add handler function
3. Wire them together in the dispatch case statement

## Constraints

- **Bash 3.2:** macOS `/bin/bash` is 3.2. No associative arrays, no `readarray`, no `${var,,}`.
- **Local-only:** Everything runs on the Mac. No cloud infrastructure for HYDRA itself.
- **Telegram limits:** 4096 char messages, HTML parse_mode (no markdown tables).
- **Cost ceiling:** Premium model (Sonnet) for coordination only. Haiku for parsing. Free models for execution.

## Security

- All API keys live in `config/telegram.env` (gitignored).
- The SQLite database is gitignored (contains runtime state).
- State and log directories are gitignored.
- The `.gitignore` covers: `config/*.env`, `hydra.db*`, `state/`, `logs/`, `reports/`, `sessions/`.
- Bot token validation happens at startup -- the listener exits if credentials are missing or placeholder values.

## Cost

~$300/month total. Sonnet handles coordination (MILO + CTO brain + reflector). Haiku handles parsing (NL commands, observer, morning planner, brain-updater). FORGE, SCOUT, and PULSE run on free HuggingFace Inference API.
