#!/bin/bash
# mempalace-canonical-sync.sh
#
# Makes MemPalace a FAITHFUL replica of the canonical file-tree brain.
#
# Source of truth = ~/.claude/projects/-Users-eddiebelaval-Development-id8/memory/
# (the MEMORY.md dispatcher + ~133 project_*/feedback_*/reference_* topic files).
# This job mirrors that tree into the MemPalace `canonical_brain` wing so its
# semantic search is always <=24h current instead of lagging ~1 week.
#
# WHY a full wipe-and-remine instead of incremental `mine`:
#   `mempalace mine` skips files it has already filed (keyed on source_file path,
#   see miner.py file_already_mined). That means NEW topic files sync, but EDITS
#   to existing files never propagate and DELETED files linger as stale drawers.
#   For a true mirror we clear the wing each run and re-mine fresh. Re-embedding
#   ~800 drawers is local (no API) and cheap enough for a daily job.
#
# Source-of-truth stays the file tree. MemPalace is the searchable replica.
# Audit + decision: ~/Development/id8/MEMORY-ARCHITECTURE-AUDIT-2026-06-01.md
#                   memory/project_memory_canonical_brain.md

set -euo pipefail

MP="$HOME/Development/mempalace/.venv/bin/mempalace"
PY="$HOME/Development/mempalace/.venv/bin/python"
BRAIN="$HOME/.claude/projects/-Users-eddiebelaval-Development-id8/memory"
PALACE="$HOME/.mempalace/palace"
WING="canonical_brain"

LOG_DIR="$HOME/Library/Logs/mempalace-canonical-sync"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(date +%Y-%m-%d).log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

log "=== canonical sync start ==="

# Guards: tooling + the mine config must exist.
[[ -x "$MP" && -x "$PY" ]] || { log "STATUS: RED  mempalace venv missing"; echo "STATUS: RED mempalace venv missing"; exit 1; }
[[ -f "$BRAIN/mempalace.yaml" ]] || { log "STATUS: RED  missing $BRAIN/mempalace.yaml (run: mempalace init)"; echo "STATUS: RED missing mempalace.yaml"; exit 1; }

# 1. Clear the wing so edits + deletions propagate (faithful mirror).
DELETED=$("$PY" - "$PALACE" "$WING" <<'PYEOF' 2>>"$LOG"
import sys, chromadb
palace, wing = sys.argv[1], sys.argv[2]
col = chromadb.PersistentClient(path=palace).get_collection("mempalace_drawers")
before = len(col.get(where={"wing": wing}, limit=1000000).get("ids", []))
if before:
    col.delete(where={"wing": wing})
print(before)
PYEOF
) || { log "STATUS: RED  wing-clear failed"; echo "STATUS: RED wing-clear failed"; exit 1; }
log "cleared $DELETED drawers from wing=$WING"

# 2. Re-mine the canonical brain fresh.
if ! "$MP" mine "$BRAIN" --wing "$WING" --agent canonical-sync >>"$LOG" 2>&1; then
    log "STATUS: RED  mine failed"; echo "STATUS: RED mine failed"; exit 1
fi

# 3. Verify + report (explicit STATUS line; never inferred from exit code alone).
AFTER=$("$PY" - "$PALACE" "$WING" <<'PYEOF' 2>>"$LOG"
import sys, chromadb
palace, wing = sys.argv[1], sys.argv[2]
col = chromadb.PersistentClient(path=palace).get_collection("mempalace_drawers")
print(len(col.get(where={"wing": wing}, limit=1000000).get("ids", [])))
PYEOF
)

if [[ "${AFTER:-0}" -gt 0 ]]; then
    log "STATUS: GREEN canonical_brain synced ($DELETED -> $AFTER drawers)"
    echo "STATUS: GREEN canonical_brain synced ($DELETED -> $AFTER drawers)"
else
    log "STATUS: RED  wing empty after mine"; echo "STATUS: RED wing empty after mine"; exit 1
fi

exit 0
