#!/bin/bash
# todo-master-refresh.sh - refresh every job's todo sensor, then rebuild the
# master. Runs before the morning briefing (8:30, briefing is 8:40) so the
# master is current. ADDITIVE: it does not touch the briefing instrument; it
# only writes sensor + master files the instrument (or a human) can read.
export PATH="/Users/eddiebelaval/.nvm/versions/node/v22.21.1/bin:$PATH"
LOG="$HOME/Library/Logs/claude-automation/todo-master.log"
echo "=== $(date) refresh ===" >> "$LOG"

# --- per-job emitters (each job adds its line here as it is built) ---
LEX="$HOME/Development/id8/lexicon"
if [ -d "$LEX" ]; then
  ( cd "$LEX" && npx tsx --env-file=.env.local scripts/emit-todo-sensor.ts ) >> "$LOG" 2>&1
fi

# ID8Labs LLC — compliance + CPA catch-up todos, derived read-only from
# llc-office/chains/sentinel/deadlines.json (resolution-aware) + state.json. No
# precondition, no env, no comms sweep — the sources are live local config.
LLC_EMIT="$HOME/Development/id8/llc-office/chains/todo-emitter/emit-todo-sensor.py"
if [ -f "$LLC_EMIT" ]; then
  python3 "$LLC_EMIT" >> "$LOG" 2>&1
fi

# Data-Tech — 2 human-decision gates (sensors/owes/datatech.json) + 2 live-DB
# derived gates (catalog imagery, seed->live swap) read read-only over PostgREST.
# Dependency-free; reads DB creds from the client repo's .env.local. NO comms sweep.
# Emits written-only and pages on stderr if the catalog is unreachable, so a bad run
# never fakes a clean list.
DT_ENV="$HOME/Development/datatech-site/.env.local"
DT_EMIT="$HOME/.hydra/tools/datatech-emit-todo-sensor.mjs"
if [ -f "$DT_ENV" ] && [ -f "$DT_EMIT" ]; then
  node --env-file="$DT_ENV" "$DT_EMIT" >> "$LOG" 2>&1
fi

# D&B (Rose Brill) install — REGULATED client. Board ADOPTED as the live store 8/13:
# reads the dnb-build tasks board (ref yhzusrkiuqjvougthgrr) read-only over PostgREST.
# NO comms sweep. Board rows are kept PII-free (tasks only). Publishable/anon key is
# sourced from the gitignored config file (never in this tracked script). If the config
# is absent the emitter falls back to the (currently empty) owes file and says so.
DNB_EMIT="$HOME/.hydra/tools/dnb-emit-todo-sensor.py"
DNB_ENV="$HOME/.hydra/config/dnb-board.env"
if [ -f "$DNB_EMIT" ]; then
  ( [ -f "$DNB_ENV" ] && set -a && . "$DNB_ENV" && set +a; python3 "$DNB_EMIT" ) >> "$LOG" 2>&1
fi

# --- the reader: merge all sensors into the master ---
python3 "$HOME/.hydra/tools/master-todo.py" --json "$HOME/.hydra/briefings/master-todo.json" >> "$LOG" 2>&1
python3 "$HOME/.hydra/tools/master-todo.py" > "$HOME/.hydra/briefings/master-todo.md" 2>> "$LOG"
echo "master refreshed: $(wc -l < "$HOME/.hydra/briefings/master-todo.md") lines" >> "$LOG"
