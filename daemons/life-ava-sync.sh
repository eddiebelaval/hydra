#!/bin/bash
# life-ava-sync.sh - HYDRA Life Triad: Ava Data Bridge
#
# Runs every Sunday at 10 AM via launchd.
# Pulls Eddie's session data from Parallax Supabase (solo_memory,
# behavioral_signals, emotional temperature trends, growth_snapshots)
# and synthesizes it into ~/life/ observations via Claude Haiku.
#
# This is the bridge between Ava's model of Eddie and Eddie's model of himself.
# Same data, different consumer.
#
# Part of the Life Triad system.

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

source "$HOME/.hydra/lib/hydra-common.sh"

LOG_DIR="$HOME/Library/Logs/claude-automation/hydra-life-ava-sync"
LOG_FILE="$LOG_DIR/ava-sync.log"
STATE_FILE="$HYDRA_ROOT/state/life-ava-sync-state.json"
LIFE_DIR="$HOME/life"
SYNC_DIR="$LIFE_DIR/.ava-sync"
PARALLAX_ENV="$HOME/Development/id8/products/parallax/.env.local"

mkdir -p "$LOG_DIR" "$SYNC_DIR" "$HYDRA_ROOT/state"

log "=== Ava sync started ==="

# ============================================================================
# LOAD PARALLAX CREDENTIALS
# ============================================================================

require_env_file "$PARALLAX_ENV"
SUPABASE_URL=$(load_env_var "$PARALLAX_ENV" "NEXT_PUBLIC_SUPABASE_URL")
SERVICE_KEY=$(load_env_var "$PARALLAX_ENV" "SUPABASE_SERVICE_ROLE_KEY")

if [[ -z "$SUPABASE_URL" || -z "$SERVICE_KEY" ]]; then
    log "ERROR: Missing Supabase credentials"
    exit 1
fi

ANTHROPIC_API_KEY=$(load_env_var "$PARALLAX_ENV" "ANTHROPIC_API_KEY")
if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    ANTHROPIC_API_KEY=$(load_env_var "$HYDRA_ROOT/config/telegram.env" "ANTHROPIC_API_KEY")
fi

log "Credentials loaded"

# ============================================================================
# FIND EDDIE'S USER ID
# ============================================================================

EDDIE_USER_ID=$(python3 << PYEOF
import json, urllib.request, sys

url = "${SUPABASE_URL}/rest/v1/user_profiles?select=user_id,solo_memory&order=updated_at.desc&limit=10"
req = urllib.request.Request(url, headers={
    "apikey": "${SERVICE_KEY}",
    "Authorization": "Bearer ${SERVICE_KEY}",
    "Content-Type": "application/json"
})

try:
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())
        if data:
            best = max(data, key=lambda p: (p.get('solo_memory') or {}).get('sessionCount', 0))
            print(best['user_id'])
        else:
            print('')
except urllib.error.URLError as e:
    print(f'ERROR: {e}', file=sys.stderr)
    print('')
PYEOF
)

if [[ -z "$EDDIE_USER_ID" || "$EDDIE_USER_ID" == "ERROR"* ]]; then
    log "ERROR: Could not find Eddie's user ID"
    exit 1
fi

log "Eddie's user ID: $EDDIE_USER_ID"

# ============================================================================
# PULL DATA FROM PARALLAX SUPABASE
# ============================================================================

SYNC_REPORT="$SYNC_DIR/sync-$(date +%Y-%m-%d).json"

python3 << PYEOF
import json, urllib.request, urllib.error, sys
from datetime import datetime

SUPABASE_URL = "${SUPABASE_URL}"
SERVICE_KEY = "${SERVICE_KEY}"
USER_ID = "${EDDIE_USER_ID}"

def supabase_get(endpoint):
    url = f"{SUPABASE_URL}/rest/v1/{endpoint}"
    req = urllib.request.Request(url, headers={
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json"
    })
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.URLError as e:
        print(f"Warning: Failed to fetch {endpoint}: {e}", file=sys.stderr)
        return []

report = {
    "synced_at": datetime.now().isoformat(),
    "user_id": USER_ID,
    "sections": {}
}

# 1. Solo Memory (the goldmine)
profiles = supabase_get(f"user_profiles?user_id=eq.{USER_ID}&select=solo_memory,life_stage,interview_completed,updated_at")
if profiles and profiles[0].get('solo_memory'):
    sm = profiles[0]['solo_memory']
    report['sections']['solo_memory'] = {
        'themes': sm.get('themes', []),
        'patterns': sm.get('patterns', []),
        'values': sm.get('values', []),
        'strengths': sm.get('strengths', []),
        'emotional_state': sm.get('emotionalState'),
        'current_situation': sm.get('currentSituation'),
        'action_items': sm.get('actionItems', []),
        'narrative_summary': sm.get('narrativeSummary'),
        'narrative_cards': sm.get('narrativeCards'),
        'life_sections': sm.get('lifeSections'),
        'session_count': sm.get('sessionCount', 0),
        'last_seen': sm.get('lastSeenAt'),
        'recent_sessions': sm.get('recentSessions', [])
    }
    report['sections']['life_stage'] = profiles[0].get('life_stage')

# 2. Behavioral Signals
signals = supabase_get(f"behavioral_signals?user_id=eq.{USER_ID}&select=signal_type,signal_value,confidence,source,updated_at")
if signals:
    report['sections']['behavioral_signals'] = [
        {
            'type': s['signal_type'],
            'value': s['signal_value'],
            'confidence': s['confidence'],
            'source': s['source'],
            'updated': s['updated_at']
        }
        for s in signals
    ]

# 3. Growth Snapshots (last 10)
snapshots = supabase_get(f"growth_snapshots?user_id=eq.{USER_ID}&select=temperature,patterns,themes,snapshot_at&order=snapshot_at.desc&limit=10")
if snapshots:
    report['sections']['growth_snapshots'] = snapshots

# 4. Recent emotional temperatures (last 50 messages from Ava sessions)
sessions = supabase_get(f"sessions?or=(person_a_user_id.eq.{USER_ID},person_b_user_id.eq.{USER_ID})&mode=in.(solo,ava)&select=id&order=updated_at.desc&limit=3")
if sessions:
    session_ids = ','.join([s['id'] for s in sessions])
    messages = supabase_get(f"messages?session_id=in.({session_ids})&sender=eq.person_a&select=emotional_temperature,metadata,created_at&order=created_at.desc&limit=50")
    if messages:
        temps = [m['emotional_temperature'] for m in messages if m.get('emotional_temperature') is not None]
        shadow_obs = []
        for m in messages:
            meta = m.get('metadata') or {}
            if meta.get('shadow_tier'):
                shadow_obs.append({
                    'tier': meta['shadow_tier'],
                    'observation': meta.get('shadow_observation', ''),
                    'confidence': meta.get('shadow_confidence'),
                    'date': m['created_at']
                })
        report['sections']['emotional_temperature'] = {
            'recent_avg': sum(temps) / len(temps) if temps else None,
            'recent_high': max(temps) if temps else None,
            'recent_low': min(temps) if temps else None,
            'sample_size': len(temps),
            'trend': temps[:10]
        }
        if shadow_obs:
            report['sections']['shadow_observations'] = shadow_obs

# 5. Predictive Insights
insights = supabase_get(f"predictive_insights?user_id=eq.{USER_ID}&select=insight_type,title,description,confidence,created_at&order=created_at.desc&limit=5")
if insights:
    report['sections']['predictive_insights'] = insights

# 6. Notes (private journal entries)
notes = supabase_get(f"notes?user_id=eq.{USER_ID}&select=title,content,created_at&order=created_at.desc&limit=5&archived=eq.false")
if notes:
    report['sections']['recent_notes'] = [
        {'title': n.get('title', ''), 'snippet': (n.get('content', '')[:200] + '...' if len(n.get('content', '')) > 200 else n.get('content', '')), 'date': n['created_at']}
        for n in notes
    ]

with open("${SYNC_REPORT}", 'w') as f:
    json.dump(report, f, indent=2, default=str)

print(f"Sync report written: {len(report['sections'])} sections")
PYEOF

log "Data pulled from Parallax Supabase"

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

life_files = {}
for fname in ['NOW.md', 'GOALS.md', 'BODY.md', 'RHYTHM.md']:
    fpath = os.path.expanduser(f"~/life/{fname}")
    try:
        with open(fpath) as f:
            life_files[fname] = f.read()[:500]
    except (IOError, OSError):
        pass

prompt = f"""You are a synthesis engine for a personal life tracking system.

Eddie talks to Ava (an AI companion) regularly. Below is data from his recent Ava sessions.
Your job: extract observations relevant to Eddie's ~/life/ system.

AVA SESSION DATA:
{json.dumps(report['sections'], indent=2, default=str)[:8000]}

CURRENT LIFE FILES (for context):
{json.dumps(life_files, indent=2)[:2000]}

Generate a JSON response with these keys:
- "now_updates": observations for NOW.md (emotional state, current situation, mental state)
- "goals_updates": action items or goals Eddie mentioned to Ava
- "body_updates": any health, energy, sleep, or physical observations
- "rhythm_updates": session timing patterns, frequency
- "blind_spots": patterns Ava detected that Eddie may not see (behavioral signals, shadow observations, recurring themes)
- "people_updates": relationship dynamics mentioned

Each value should be an array of short, factual observation strings.
Only include sections where there's actual data. Skip empty sections.
Be factual, not interpretive. Use Eddie's own words where possible.
"""

synthesis = call_claude(prompt, max_tokens=1500, api_key="${ANTHROPIC_API_KEY}")
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

BLIND_SPOTS_FILE="$LIFE_DIR/.blind-spots/ava-observations.md"

python3 << PYEOF
import sys, os
sys.path.insert(0, os.path.expanduser('~/.hydra/lib'))
from observations import write_observations

write_observations(
    "${STAGING_FILE}",
    "${BLIND_SPOTS_FILE}",
    "Ava Observations",
    "*Synthesized from Parallax session data. Written by the Ava bridge daemon, not by Eddie.*\n*These are patterns Ava detected across sessions \u2014 emotional trends, behavioral signals, recurring themes.*",
    [('now_updates', 'State of Mind'), ('body_updates', 'Body/Energy'),
     ('rhythm_updates', 'Rhythm'), ('blind_spots', 'Blind Spots'),
     ('people_updates', 'Relationships'), ('goals_updates', 'Goals/Actions')]
)
PYEOF

log "Blind spots updated"

SUMMARY=$(python3 << PYEOF
import sys, os
sys.path.insert(0, os.path.expanduser('~/.hydra/lib'))
from observations import build_summary

print(build_summary(
    "${STAGING_FILE}",
    "Ava sync",
    ['now_updates', 'blind_spots', 'goals_updates']))
PYEOF
)

"$NOTIFY" silent "Ava Sync" "$SUMMARY" "" 2>/dev/null || true

update_state "$STATE_FILE" "last_sync=$(date +%Y-%m-%d)" "sync_count+=1"
log_activity "life_ava_sync" "system" "life-triad" "Ava bridge: session data synced to ~/life/"

log "=== Ava sync complete ==="
echo "Ava sync: complete"
