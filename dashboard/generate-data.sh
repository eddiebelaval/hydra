#!/bin/bash
# generate-data.sh - HYDRA Morning Dashboard Data Generator
# Replaces: generate-empire-data.sh (subway map)
# Output: ~/.hydra/dashboard/data.json
# Runs: 6:00 AM daily via launchd + on-demand from server.py

set -euo pipefail

HYDRA_DB="$HOME/.hydra/hydra.db"
HYDRA_BASE="$HOME/.hydra"
OUT="$HYDRA_BASE/dashboard/data.json"
LOGS_BASE="$HOME/Library/Logs/claude-automation"
DATE=$(date +%Y-%m-%d)
DAY_NAME=$(date +%A)
WEEK=$(date +%Y-W%V)
MONTH=$(date +%Y-%m)
QUARTER="Q$(( ($(date +%-m) - 1) / 3 + 1 ))-$(date +%Y)"

# Helper: run sqlite3 query, return empty string on failure
q() { sqlite3 "$HYDRA_DB" "$1" 2>/dev/null || echo ""; }

# ── Today's Priorities ──
PRIORITIES_JSON=$(python3 << PYEOF
import sqlite3, json
conn = sqlite3.connect("$HYDRA_DB")
rows = conn.execute("""
    SELECT priority_number, description, status, notes
    FROM daily_priorities WHERE date = '$DATE'
    ORDER BY priority_number
""").fetchall()
print(json.dumps([{"num": r[0], "desc": r[1], "status": r[2], "notes": r[3]} for r in rows]))
PYEOF
)

# ── Goals (all horizons) ──
GOALS_JSON=$(python3 << PYEOF
import sqlite3, json
conn = sqlite3.connect("$HYDRA_DB")
rows = conn.execute("""
    SELECT id, horizon, period, description, status, progress, category, parent_id, notes, target_date
    FROM goals ORDER BY
        CASE horizon WHEN 'quarterly' THEN 1 WHEN 'monthly' THEN 2 WHEN 'weekly' THEN 3 END,
        CASE status WHEN 'active' THEN 1 WHEN 'carried' THEN 2 WHEN 'revised' THEN 3 WHEN 'achieved' THEN 4 WHEN 'dropped' THEN 5 END,
        created_at
""").fetchall()
print(json.dumps([{
    "id": r[0], "horizon": r[1], "period": r[2], "description": r[3],
    "status": r[4], "progress": r[5], "category": r[6], "parent_id": r[7],
    "notes": r[8], "target_date": r[9]
} for r in rows]))
PYEOF
)

# ── Weekly Focus ──
WEEKLY_JSON=$(python3 << PYEOF
import sqlite3, json
conn = sqlite3.connect("$HYDRA_DB")
row = conn.execute("SELECT week, theme, items, retrospective FROM weekly_focus WHERE week = '$WEEK'").fetchone()
if row:
    print(json.dumps({"week": row[0], "theme": row[1], "items": json.loads(row[2] or "[]"), "retro": row[3]}))
else:
    print(json.dumps({"week": "$WEEK", "theme": None, "items": [], "retro": None}))
PYEOF
)

# ── Agent Workload ──
AGENTS_JSON=$(python3 << PYEOF
import sqlite3, json
conn = sqlite3.connect("$HYDRA_DB")
rows = conn.execute("SELECT agent_name, pending_tasks, in_progress_tasks, completed_today FROM v_agent_workload ORDER BY pending_tasks + in_progress_tasks DESC").fetchall()
print(json.dumps([{"name": r[0], "pending": r[1], "wip": r[2], "done_today": r[3]} for r in rows]))
PYEOF
)

# ── High Priority + Blocked Tasks ──
TASKS_JSON=$(python3 << PYEOF
import sqlite3, json
conn = sqlite3.connect("$HYDRA_DB")
high = conn.execute("""
    SELECT COALESCE(assigned_to, 'unassigned'), title, priority, status, due_at
    FROM tasks WHERE status IN ('pending', 'in_progress') AND priority <= 2
    ORDER BY priority, created_at
""").fetchall()
blocked = conn.execute("""
    SELECT COALESCE(assigned_to, 'unassigned'), title, blocked_reason
    FROM tasks WHERE status = 'blocked'
""").fetchall()
urgent_count = conn.execute("SELECT COUNT(*) FROM notifications WHERE delivered = 0 AND priority = 'urgent'").fetchone()[0]
total_notif = conn.execute("SELECT COUNT(*) FROM notifications WHERE delivered = 0").fetchone()[0]
print(json.dumps({
    "high_priority": [{"agent": r[0], "title": r[1], "priority": r[2], "status": r[3], "due": r[4]} for r in high],
    "blocked": [{"agent": r[0], "title": r[1], "reason": r[2]} for r in blocked],
    "urgent_count": urgent_count,
    "notification_count": total_notif
}))
PYEOF
)

# ── Yesterday's Wins ──
YESTERDAY_JSON=$(python3 << PYEOF
import sqlite3, json
conn = sqlite3.connect("$HYDRA_DB")
rows = conn.execute("""
    SELECT COALESCE(assigned_to, 'unassigned'), title
    FROM tasks WHERE status = 'completed' AND date(completed_at) = date('now', '-1 day')
    ORDER BY completed_at DESC
""").fetchall()
print(json.dumps([{"agent": r[0], "title": r[1]} for r in rows]))
PYEOF
)

# ── Project Activity (from brain-updater) ──
PROJECT_ACTIVITY=""
BRAIN_FILE="$HYDRA_BASE/TECHNICAL_BRAIN.md"
if [[ -f "$BRAIN_FILE" ]]; then
    PROJECT_ACTIVITY=$(sed -n '/<!-- BRAIN-UPDATER:START -->/,/<!-- BRAIN-UPDATER:END -->/{
        /<!-- BRAIN-UPDATER/d
        /^## Recent Git Activity/d
        /^\*Auto-updated/d
        p
    }' "$BRAIN_FILE" 2>/dev/null | sed '1{/^$/d;}' || echo "")
fi

# ── Automation Signals ──
SIGNALS_JSON=$(python3 << PYEOF
import json, os, glob

signals = {}
logs_base = os.path.expanduser("~/Library/Logs/claude-automation")

# 70% detector
reports = sorted(glob.glob(f"{logs_base}/seventy-percent-detector/report-*.md"), reverse=True)
if reports:
    with open(reports[0]) as f:
        count = sum(1 for line in f if line.startswith("- "))
    if count > 0:
        signals["seventy_pct"] = count

# Marketing streak
streak_file = f"{logs_base}/marketing-check/.marketing-streak"
if os.path.exists(streak_file):
    with open(streak_file) as f:
        signals["marketing_streak"] = int(f.read().split(":")[0].strip() or "0")

# Focus score
focus_reports = sorted(glob.glob(f"{logs_base}/context-switch/report-*.md"), reverse=True)
if focus_reports:
    with open(focus_reports[0]) as f:
        for line in f:
            if "Focus Score" in line:
                import re
                m = re.search(r'(\d+)', line)
                if m:
                    signals["focus_score"] = int(m.group(1))
                break

print(json.dumps(signals))
PYEOF
)

# ── System Health ──
HEALTH_JSON=$("$HYDRA_BASE/tools/hydra-health-summary.sh" json 2>/dev/null || echo "")
if [[ -z "$HEALTH_JSON" ]] || ! python3 -c "import json; json.loads('''$HEALTH_JSON''')" 2>/dev/null; then
    # Parse the text output into JSON
    HEALTH_TEXT=$("$HYDRA_BASE/tools/hydra-health-summary.sh" full 2>/dev/null || echo "")
    HEALTH_JSON=$(python3 -c "
import json, re, sys
text = '''$HEALTH_TEXT'''
# Extract status from header
status = 'unknown'
if 'CRITICAL' in text: status = 'critical'
elif 'WARNING' in text: status = 'warning'
elif 'OK' in text or 'HEALTHY' in text: status = 'healthy'
# Extract table rows
checks = []
for line in text.split('\n'):
    if '|' in line and line.strip().startswith('|') and 'Check' not in line and '---' not in line:
        parts = [p.strip() for p in line.split('|') if p.strip()]
        if len(parts) >= 4:
            checks.append({'check': parts[0], 'component': parts[1], 'status': parts[2], 'details': parts[3] if len(parts) > 3 else ''})
print(json.dumps({'status': status, 'checks': checks}))
" 2>/dev/null || echo '{"status":"unknown","checks":[]}')
fi

# ── Recent Observations (last 48h) ──
OBS_JSON=$(python3 << PYEOF
import sqlite3, json
conn = sqlite3.connect("$HYDRA_DB")
rows = conn.execute("""
    SELECT date, priority, content, source
    FROM observations WHERE date >= date('now', '-2 days')
    ORDER BY timestamp DESC LIMIT 10
""").fetchall()
print(json.dumps([{"date": r[0], "priority": r[1], "content": r[2], "source": r[3]} for r in rows]))
PYEOF
)

# ── Recent Reflections ──
REFLECTIONS_JSON=$(python3 << PYEOF
import sqlite3, json
conn = sqlite3.connect("$HYDRA_DB")
rows = conn.execute("""
    SELECT pattern, priority, period_start, period_end
    FROM reflections ORDER BY created_at DESC LIMIT 5
""").fetchall()
print(json.dumps([{"pattern": r[0], "priority": r[1], "start": r[2], "end": r[3]} for r in rows]))
PYEOF
)

# ── Goal Check-in History (last 14 days) ──
CHECKINS_JSON=$(python3 << PYEOF
import sqlite3, json
conn = sqlite3.connect("$HYDRA_DB")
rows = conn.execute("""
    SELECT gc.goal_id, gc.date, gc.progress, gc.note, gc.source, g.description
    FROM goal_checkins gc JOIN goals g ON gc.goal_id = g.id
    WHERE gc.date >= date('now', '-14 days')
    ORDER BY gc.date DESC
""").fetchall()
print(json.dumps([{"goal_id": r[0], "date": r[1], "progress": r[2], "note": r[3], "source": r[4], "goal": r[5]} for r in rows]))
PYEOF
)

# ── Export all JSON fragments as env vars for the assembler ──
export DASH_PRIORITIES="$PRIORITIES_JSON"
export DASH_GOALS="$GOALS_JSON"
export DASH_WEEKLY="$WEEKLY_JSON"
export DASH_AGENTS="$AGENTS_JSON"
export DASH_TASKS="$TASKS_JSON"
export DASH_YESTERDAY="$YESTERDAY_JSON"
export DASH_SIGNALS="$SIGNALS_JSON"
export DASH_HEALTH="$HEALTH_JSON"
export DASH_OBS="$OBS_JSON"
export DASH_REFLECTIONS="$REFLECTIONS_JSON"
export DASH_CHECKINS="$CHECKINS_JSON"

# ── Write project activity to temp file (avoids quote escaping issues) ──
ACTIVITY_TMP=$(mktemp)
echo "$PROJECT_ACTIVITY" > "$ACTIVITY_TMP"

# ── Assemble final JSON ──
GENERATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

python3 - "$OUT" "$DATE" "$DAY_NAME" "$WEEK" "$MONTH" "$QUARTER" "$GENERATED_AT" "$ACTIVITY_TMP" << 'PYEOF'
import json, sys, os

out_path = sys.argv[1]
date, day, week, month, quarter, generated_at, activity_file = sys.argv[2:9]

# Read pre-computed JSON fragments from env
def load_env(key):
    val = os.environ.get(key, "[]")
    try:
        return json.loads(val)
    except:
        return val

# Read project activity from temp file
activity = ""
try:
    with open(activity_file) as f:
        activity = f.read().strip()
    os.unlink(activity_file)
except:
    pass

data = {
    "generated_at": generated_at,
    "date": date,
    "day": day,
    "week": week,
    "month": month,
    "quarter": quarter,
    "priorities": load_env("DASH_PRIORITIES"),
    "goals": load_env("DASH_GOALS"),
    "weekly_focus": load_env("DASH_WEEKLY"),
    "agents": load_env("DASH_AGENTS"),
    "tasks": load_env("DASH_TASKS"),
    "yesterday_wins": load_env("DASH_YESTERDAY"),
    "project_activity": activity,
    "signals": load_env("DASH_SIGNALS"),
    "health": load_env("DASH_HEALTH"),
    "observations": load_env("DASH_OBS"),
    "reflections": load_env("DASH_REFLECTIONS"),
    "checkins": load_env("DASH_CHECKINS")
}

with open(out_path, "w") as f:
    json.dump(data, f, indent=2)

size = os.path.getsize(out_path)
print(f"Dashboard data written: {out_path} ({size} bytes)")
PYEOF
