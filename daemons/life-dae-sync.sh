#!/bin/bash
# life-dae-sync.sh - HYDRA Life Triad: Dae Data Bridge
#
# Runs every Monday at 9 AM via launchd (day after Oak Tree Report).
# Pulls trading data from DeepStack's SQLite + Supabase and
# synthesizes it into ~/life/ observations via Claude Haiku.
#
# Data sources:
#   - trade_journal.db (SQLite) — trades, P&L, balance
#   - Supabase: deepstack_captains_log, chat, daily_summary, performance_metrics
#   - mind/memory/lessons.md — Dae's learned patterns
#
# This bridges Dae's trading intelligence into Eddie's life system.
# Part of the Life Triad system.

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

source "$HOME/.hydra/lib/hydra-common.sh"

LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-life-dae-sync"
LOG_FILE="$LOG_DIR/dae-sync.log"
STATE_FILE="$HYDRA_ROOT/state/life-dae-sync-state.json"
LIFE_DIR="$HOME/life"
SYNC_DIR="$LIFE_DIR/.dae-sync"
DEEPSTACK_ROOT="$HOME/clawd/projects/kalshi-trading"
DEEPSTACK_ENV="$DEEPSTACK_ROOT/.env"
TRADE_DB="$DEEPSTACK_ROOT/trade_journal.db"
LESSONS_FILE="$DEEPSTACK_ROOT/kalshi_trader/mind/memory/lessons.md"
WEALTH_ENGINE="$DEEPSTACK_ROOT/kalshi_trader/mind/drives/90_day_wealth_engine.md"

mkdir -p "$LOG_DIR" "$SYNC_DIR" "$HYDRA_ROOT/state"

log "=== Dae sync started ==="

# ============================================================================
# LOAD CREDENTIALS
# ============================================================================

require_env_file "$DEEPSTACK_ENV"
DS_SUPABASE_URL=$(load_env_var "$DEEPSTACK_ENV" "SUPABASE_URL")
DS_SERVICE_KEY=$(load_env_var "$DEEPSTACK_ENV" "SUPABASE_SERVICE_ROLE_KEY")
ANTHROPIC_API_KEY=$(load_env_var "$DEEPSTACK_ENV" "ANTHROPIC_API_KEY")
if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    ANTHROPIC_API_KEY=$(load_env_var "$HYDRA_ROOT/config/telegram.env" "ANTHROPIC_API_KEY")
fi

log "Credentials loaded"

# ============================================================================
# PULL DATA
# ============================================================================

SYNC_REPORT="$SYNC_DIR/sync-$(date +%Y-%m-%d).json"

python3 << PYEOF
import json, urllib.request, urllib.error, sqlite3, os, sys
from datetime import datetime, timedelta

report = {
    "synced_at": datetime.now().isoformat(),
    "sections": {}
}

# 1. Trade Journal (SQLite) — last 7 days
trade_db = "${TRADE_DB}"
try:
    conn = sqlite3.connect(trade_db)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    week_ago = (datetime.now() - timedelta(days=7)).isoformat()

    # Recent trades (also provides latest balance via trades[0])
    cursor.execute("""
        SELECT created_at, pnl, balance FROM trades
        WHERE created_at > ?
        ORDER BY created_at DESC
        LIMIT 20
    """, (week_ago,))
    trades = [dict(r) for r in cursor.fetchall()]

    if trades:
        wins = sum(1 for t in trades if t.get('pnl', 0) > 0)
        losses = sum(1 for t in trades if t.get('pnl', 0) < 0)
        total_pnl = sum(t.get('pnl', 0) for t in trades)
        report['sections']['recent_trades'] = {
            'count': len(trades),
            'wins': wins,
            'losses': losses,
            'win_rate': round(wins / len(trades) * 100, 1) if trades else 0,
            'total_pnl': round(total_pnl, 2),
            'last_trade': trades[0].get('created_at', 'unknown')
        }
        report['sections']['latest_balance'] = trades[0]

    conn.close()
except (sqlite3.Error, FileNotFoundError) as e:
    print(f"Warning: SQLite error: {e}", file=sys.stderr)

# 2. Lessons learned (Markdown)
lessons_file = "${LESSONS_FILE}"
try:
    with open(lessons_file) as f:
        lines = [l.strip() for l in f if l.strip().startswith('- ')]
    report['sections']['lessons'] = {
        'total_count': len(lines),
        'recent': lines[-5:] if len(lines) > 5 else lines
    }
except (IOError, OSError) as e:
    print(f"Warning: Lessons read error: {e}", file=sys.stderr)

# 3. Wealth Engine status
engine_file = "${WEALTH_ENGINE}"
try:
    with open(engine_file) as f:
        content = f.read()
    if 'Phase 1' in content or 'SEED' in content:
        phase = 'Phase 1 (SEED/Diagnostics)'
    elif 'Phase 2' in content or 'GROWTH' in content:
        phase = 'Phase 2 (GROWTH)'
    elif 'Phase 3' in content or 'COMPOUND' in content:
        phase = 'Phase 3 (COMPOUNDING)'
    else:
        phase = 'Unknown'
    report['sections']['wealth_engine'] = {
        'current_phase': phase,
        'file_modified': datetime.fromtimestamp(os.path.getmtime(engine_file)).isoformat()
    }
except (IOError, OSError) as e:
    print(f"Warning: Wealth engine read error: {e}", file=sys.stderr)

# 4. Supabase — Captain's Log + Chat (last 7 days)
ds_url = "${DS_SUPABASE_URL}"
ds_key = "${DS_SERVICE_KEY}"

if ds_url and ds_key:
    def ds_get(table, columns, limit=10, since_iso=None):
        query = f"select={columns}&order=created_at.desc&limit={limit}"
        if since_iso:
            query += f"&created_at=gte.{since_iso}"
        url = f"{ds_url}/rest/v1/{table}?{query}"
        req = urllib.request.Request(url, headers={
            "apikey": ds_key,
            "Authorization": f"Bearer {ds_key}",
            "Content-Type": "application/json"
        })
        try:
            with urllib.request.urlopen(req) as resp:
                return json.loads(resp.read())
        except urllib.error.URLError as e:
            print(f"Warning: Supabase error on {table}: {e}", file=sys.stderr)
            return []

    week_ago_iso = (datetime.now() - timedelta(days=7)).strftime('%Y-%m-%dT%H:%M:%S')

    log_entries = ds_get("deepstack_captains_log", "content,created_at", limit=10, since_iso=week_ago_iso)
    if log_entries:
        report['sections']['captains_log'] = [
            {'content': e.get('content', '')[:300], 'date': e.get('created_at')}
            for e in log_entries
        ]

    chat_msgs = ds_get("chat", "role,content,created_at", limit=15, since_iso=week_ago_iso)
    if chat_msgs:
        report['sections']['recent_chat'] = [
            {'role': m.get('role', ''), 'content': m.get('content', '')[:200], 'date': m.get('created_at')}
            for m in chat_msgs
        ]

    summaries = ds_get("daily_summary", "date,total_pnl,trade_count,balance", limit=7)
    if summaries:
        report['sections']['daily_summaries'] = summaries

    metrics = ds_get("performance_metrics", "*", limit=1)
    if metrics:
        report['sections']['performance'] = metrics[0]

with open("${SYNC_REPORT}", 'w') as f:
    json.dump(report, f, indent=2, default=str)

section_count = len(report['sections'])
print(f"Sync report written: {section_count} sections")
PYEOF

log "Data pulled from DeepStack sources"

# ============================================================================
# SYNTHESIZE WITH CLAUDE HAIKU
# ============================================================================

if [[ ! -f "$SYNC_REPORT" ]]; then
    log "ERROR: Sync report not generated"
    exit 1
fi

SYNTHESIS=$(python3 << PYEOF
import json, os, sys
sys.path.insert(0, os.path.expanduser('~/.hydra/lib'))
from claude_client import call_claude

with open("${SYNC_REPORT}") as f:
    report = json.load(f)

money_content = ""
try:
    with open(os.path.expanduser("~/life/MONEY.md")) as f:
        money_content = f.read()[:800]
except (IOError, OSError):
    pass

prompt = f"""You are a synthesis engine for a personal life tracking system.

Eddie trades on Kalshi using Dae (his AI trading entity). Below is data from the past week.
Your job: extract LIFE-LEVEL observations only. NOT market data, NOT trade-by-trade details,
NOT regime analysis. This feeds into Eddie's personal life system, not a trading dashboard.

IMPORTANT: Be extremely selective. Only surface:
- Current balance (one number)
- Whether the 90-Day Wealth Engine is on track, ahead, or behind
- Any behavioral patterns that affect Eddie's LIFE (not his trades)
- Major milestones or setbacks (not individual wins/losses)

DAE TRADING DATA:
{json.dumps(report['sections'], indent=2, default=str)[:6000]}

CURRENT MONEY.md:
{money_content}

Generate a JSON response with these keys:
- "money_updates": 1-3 observations MAX. Current balance, weekly P&L summary, that's it.
- "goals_progress": 1-2 observations MAX. Is the wealth engine on track? Any phase transitions?
- "blind_spots": ONLY if there's a behavioral pattern worth noting (revenge trading, overtrading, etc). Empty array if nothing notable.

Do NOT include: individual trade details, market regime data, strategy names, technical indicators.
Keep it at the altitude of "how's the money part of life going?" not "how's the trading going?"

Each value should be an array of short, factual observation strings (1-3 per section MAX).
"""

synthesis = call_claude(prompt, api_key="${ANTHROPIC_API_KEY}")
print(json.dumps(synthesis, indent=2))
PYEOF
)

if [[ -z "$SYNTHESIS" ]]; then
    log "ERROR: Synthesis failed"
    exit 1
fi

STAGING_FILE="$SYNC_DIR/synthesis-$(date +%Y-%m-%d).json"
echo "$SYNTHESIS" > "$STAGING_FILE"

log "Synthesis complete: $STAGING_FILE"

# ============================================================================
# WRITE OBSERVATIONS, NOTIFY, UPDATE STATE
# ============================================================================

BLIND_SPOTS_FILE="$LIFE_DIR/.blind-spots/dae-observations.md"

python3 << PYEOF
import sys, os
sys.path.insert(0, os.path.expanduser('~/.hydra/lib'))
from observations import write_observations

write_observations(
    "${STAGING_FILE}",
    "${BLIND_SPOTS_FILE}",
    "Dae Observations",
    "*Synthesized from DeepStack trading data. Written by the Dae bridge daemon.*\n*Trading patterns, P&L trends, behavioral observations from Dae's perspective.*",
    [('money_updates', 'Financial State'), ('goals_progress', 'Wealth Engine Progress'),
     ('blind_spots', 'Trading Behavior'), ('lessons', 'New Lessons')]
)
PYEOF

log "Blind spots updated"

SUMMARY=$(python3 << PYEOF
import sys, os
sys.path.insert(0, os.path.expanduser('~/.hydra/lib'))
from observations import build_summary

print(build_summary(
    "${STAGING_FILE}",
    "Dae sync",
    ['money_updates', 'goals_progress', 'blind_spots']))
PYEOF
)

"$NOTIFY" silent "Dae Sync" "$SUMMARY" "" 2>/dev/null || true

update_state "$STATE_FILE" "last_sync=$(date +%Y-%m-%d)" "sync_count+=1"
log_activity "life_dae_sync" "system" "life-triad" "Dae bridge: trading data synced to ~/life/"

log "=== Dae sync complete ==="
echo "Dae sync: complete"
