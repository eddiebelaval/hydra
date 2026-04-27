#!/bin/bash
# kb-lint-daemon.sh - Knowledge Base Health Checker
#
# Runs weekly Sunday 6 AM via launchd.
# Iterates all KBs in knowledge/manifest.json and checks:
#   - Directory structure (raw/, wiki/, output/ exist)
#   - File counts per layer
#   - Orphaned raw files (no corresponding wiki article)
#   - Updates health.md per KB
#   - Generates aggregate report
#
# Pure bash -- no LLM calls needed.

set -eo pipefail

KB_ROOT="$HOME/Development/id8/knowledge"
MANIFEST="$KB_ROOT/manifest.json"
LOG_DIR="$HOME/Library/Logs/claude-automation/kb-lint"
DATE=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/lint-$DATE.log"
REPORT_FILE="$LOG_DIR/report-$DATE.md"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p "$LOG_DIR"

log() {
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
}

log "=== KB lint starting ==="

if [[ ! -f "$MANIFEST" ]]; then
    log "ERROR: manifest.json not found at $MANIFEST"
    exit 1
fi

# Parse KB names from manifest
KB_NAMES=$(python3 -c "
import json
with open('$MANIFEST') as f:
    data = json.load(f)
for kb in data.get('kbs', []):
    print(kb['name'] + '|' + kb.get('path', kb['name']) + '|' + kb.get('type', 'standard'))
" 2>/dev/null)

if [[ -z "$KB_NAMES" ]]; then
    log "ERROR: No KBs found in manifest"
    exit 1
fi

TOTAL=0
HEALTHY=0
DEGRADED=0
EMPTY=0

REPORT="# Knowledge Base Health Report -- $DATE\n\n"
REPORT+="| KB | Type | Raw | Wiki | Output | Orphans | Status |\n"
REPORT+="|------|------|-----|------|--------|---------|--------|\n"

while IFS='|' read -r name path kb_type; do
    TOTAL=$((TOTAL + 1))
    KB_DIR="$KB_ROOT/$path"

    if [[ ! -d "$KB_DIR" ]]; then
        log "  SKIP: $name -- directory not found ($KB_DIR)"
        REPORT+="| $name | $kb_type | - | - | - | - | MISSING |\n"
        DEGRADED=$((DEGRADED + 1))
        continue
    fi

    # Count files per layer
    RAW_COUNT=0
    WIKI_COUNT=0
    OUTPUT_COUNT=0

    [[ -d "$KB_DIR/raw" ]] && RAW_COUNT=$(find "$KB_DIR/raw" -type f 2>/dev/null | wc -l | tr -d ' ')
    [[ -d "$KB_DIR/wiki" ]] && WIKI_COUNT=$(find "$KB_DIR/wiki" -type f -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    [[ -d "$KB_DIR/output" ]] && OUTPUT_COUNT=$(find "$KB_DIR/output" -type f 2>/dev/null | wc -l | tr -d ' ')

    # Check for missing directories
    MISSING_DIRS=""
    [[ ! -d "$KB_DIR/raw" ]] && MISSING_DIRS+="raw "
    [[ ! -d "$KB_DIR/wiki" ]] && MISSING_DIRS+="wiki "
    [[ ! -d "$KB_DIR/output" ]] && MISSING_DIRS+="output "

    # Count orphaned raw files (real files only, with no matching wiki article).
    # Symlinks in raw/ are intentional pointers to canonical docs elsewhere
    # (e.g. ~/Documents/ID8Labs-LLC), not orphan raw content awaiting compilation.
    ORPHAN_COUNT=0
    if [[ -d "$KB_DIR/raw" ]] && [[ -d "$KB_DIR/wiki" ]]; then
        for raw_file in "$KB_DIR/raw"/*; do
            [[ -f "$raw_file" ]] || continue
            [[ -L "$raw_file" ]] && continue
            base=$(basename "$raw_file" | sed 's/\.[^.]*$//')
            # Check if any wiki file references this
            if ! grep -rl "$base" "$KB_DIR/wiki/" >/dev/null 2>&1; then
                ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
            fi
        done
    fi

    # Determine status
    TOTAL_FILES=$((RAW_COUNT + WIKI_COUNT + OUTPUT_COUNT))
    if [[ "$TOTAL_FILES" -eq 0 ]]; then
        STATUS="EMPTY"
        EMPTY=$((EMPTY + 1))
    elif [[ -n "$MISSING_DIRS" ]] || [[ "$ORPHAN_COUNT" -gt 5 ]]; then
        STATUS="DEGRADED"
        DEGRADED=$((DEGRADED + 1))
    else
        STATUS="HEALTHY"
        HEALTHY=$((HEALTHY + 1))
    fi

    # Update health.md
    HEALTH_FILE="$KB_DIR/health.md"
    cat > "$HEALTH_FILE" << HEALTH_EOF
# $name KB Health

Last lint: $DATE
Status: $STATUS

## Metrics
- Raw files: $RAW_COUNT
- Wiki articles: $WIKI_COUNT
- Output files: $OUTPUT_COUNT
- Orphaned raw files: $ORPHAN_COUNT
$(if [[ -n "$MISSING_DIRS" ]]; then echo "- Missing directories: $MISSING_DIRS"; fi)

## Type
$kb_type
HEALTH_EOF

    REPORT+="| $name | $kb_type | $RAW_COUNT | $WIKI_COUNT | $OUTPUT_COUNT | $ORPHAN_COUNT | $STATUS |\n"
    log "  $name: raw=$RAW_COUNT wiki=$WIKI_COUNT output=$OUTPUT_COUNT orphans=$ORPHAN_COUNT status=$STATUS"

done <<< "$KB_NAMES"

# Summary
REPORT+="\n## Summary\n\n"
REPORT+="- **Total KBs:** $TOTAL\n"
REPORT+="- **Healthy:** $HEALTHY\n"
REPORT+="- **Degraded:** $DEGRADED\n"
REPORT+="- **Empty:** $EMPTY\n"
REPORT+="\n*Generated $TIMESTAMP*\n"

echo -e "$REPORT" > "$REPORT_FILE"
log "Report written to $REPORT_FILE"
log "=== KB lint complete: $HEALTHY healthy, $DEGRADED degraded, $EMPTY empty ==="
