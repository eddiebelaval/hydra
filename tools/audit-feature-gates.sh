#!/bin/bash
# audit-feature-gates.sh — Scan Parallax for all tier/premium checks
# Outputs a FEATURE_GATE_MAP.md with current gating state
#
# Usage: bash ~/.hydra/tools/audit-feature-gates.sh [--output FILE]
#
# Scans for: isPremium, .plan, tier checks, subscription gating,
# billing limit checks, and conditional feature access.

set -euo pipefail

PARALLAX_DIR="$HOME/Development/id8/products/parallax"
OUTPUT="$PARALLAX_DIR/FEATURE_GATE_MAP.md"

if [[ "${1:-}" == "--output" ]] && [[ -n "${2:-}" ]]; then
    OUTPUT="$2"
elif [[ -n "${1:-}" ]]; then
    OUTPUT="$1"
fi

cd "$PARALLAX_DIR"

echo "Scanning Parallax for feature gates..."

# Collect all tier-related patterns with file:line:content
PATTERNS='isPremium|\.plan\b|subscription\.plan|tier\b|FREE_TIER|PRO_TIER|PREMIUM_TIER|check_and_increment|TIER_LIMITS|tierToLimits|priceIdToTier|UpgradePrompt|checkSubscription'

# Get raw matches (exclude tests, node_modules, .next)
MATCHES=$(grep -rEn "$PATTERNS" src/ \
    --include="*.ts" --include="*.tsx" \
    --exclude-dir=__tests__ \
    --exclude-dir=node_modules \
    --exclude-dir=.next \
    2>/dev/null || echo "")

# Count files and matches
FILE_COUNT=$(echo "$MATCHES" | grep -v '^$' | cut -d: -f1 | sort -u | wc -l | tr -d ' ')
MATCH_COUNT=$(echo "$MATCHES" | grep -v '^$' | wc -l | tr -d ' ')

# Categorize by location
API_ROUTES=$(echo "$MATCHES" | grep "src/app/api/" | cut -d: -f1 | sort -u || echo "")
COMPONENTS=$(echo "$MATCHES" | grep "src/components/" | cut -d: -f1 | sort -u || echo "")
HOOKS=$(echo "$MATCHES" | grep "src/hooks/" | cut -d: -f1 | sort -u || echo "")
LIB=$(echo "$MATCHES" | grep "src/lib/" | cut -d: -f1 | sort -u || echo "")
TYPES=$(echo "$MATCHES" | grep "src/types/" | cut -d: -f1 | sort -u || echo "")
PAGES=$(echo "$MATCHES" | grep -E "src/app/[^a]" | grep -v "src/app/api/" | cut -d: -f1 | sort -u || echo "")

# Generate the map
cat > "$OUTPUT" << 'HEADER'
# Feature Gate Map

Auto-generated audit of all tier/premium/subscription checks in Parallax.

HEADER

echo "**Generated:** $(date '+%Y-%m-%d %H:%M')" >> "$OUTPUT"
echo "**Files scanned:** $FILE_COUNT with gate logic" >> "$OUTPUT"
echo "**Total gate references:** $MATCH_COUNT" >> "$OUTPUT"
echo "" >> "$OUTPUT"

# Tier config (source of truth)
echo "## Tier Definitions (source of truth)" >> "$OUTPUT"
echo "" >> "$OUTPUT"
echo '```' >> "$OUTPUT"
cat src/lib/billing/tier-config.ts >> "$OUTPUT"
echo '```' >> "$OUTPUT"
echo "" >> "$OUTPUT"

# API Routes — most important for enforcement
echo "## API Route Gates (server-side enforcement)" >> "$OUTPUT"
echo "" >> "$OUTPUT"
echo "These are the actual enforcement points. If a feature is gated, it must be gated HERE." >> "$OUTPUT"
echo "" >> "$OUTPUT"

if [[ -n "$API_ROUTES" ]]; then
    echo "$API_ROUTES" | while read -r file; do
        route_name=$(echo "$file" | sed 's|src/app/api/||' | sed 's|/route\.ts||')
        gate_lines=$(grep -En "$PATTERNS" "$file" 2>/dev/null | head -5)
        echo "### \`/api/$route_name\`" >> "$OUTPUT"
        echo '```' >> "$OUTPUT"
        echo "$gate_lines" >> "$OUTPUT"
        echo '```' >> "$OUTPUT"
        echo "" >> "$OUTPUT"
    done
fi

# Components — UI-level gating
echo "## Component Gates (UI-level)" >> "$OUTPUT"
echo "" >> "$OUTPUT"
echo "These control what users SEE. Should mirror API gates, not replace them." >> "$OUTPUT"
echo "" >> "$OUTPUT"

if [[ -n "$COMPONENTS" ]]; then
    echo "$COMPONENTS" | while read -r file; do
        comp_name=$(basename "$file" .tsx)
        gate_count=$(grep -Ec "$PATTERNS" "$file" 2>/dev/null || echo "0")
        echo "- **$comp_name** ($gate_count references) — \`$file\`" >> "$OUTPUT"
    done
    echo "" >> "$OUTPUT"
fi

# Hooks
echo "## Hook Gates" >> "$OUTPUT"
echo "" >> "$OUTPUT"
if [[ -n "$HOOKS" ]]; then
    echo "$HOOKS" | while read -r file; do
        hook_name=$(basename "$file" .ts)
        echo "- **$hook_name** — \`$file\`" >> "$OUTPUT"
    done
    echo "" >> "$OUTPUT"
fi

# Pages
echo "## Page-Level Gates" >> "$OUTPUT"
echo "" >> "$OUTPUT"
if [[ -n "$PAGES" ]]; then
    echo "$PAGES" | while read -r file; do
        page_path=$(echo "$file" | sed 's|src/app/||' | sed 's|/page\.tsx||')
        echo "- **/$page_path** — \`$file\`" >> "$OUTPUT"
    done
    echo "" >> "$OUTPUT"
fi

# Summary matrix
echo "## Gate Matrix Summary" >> "$OUTPUT"
echo "" >> "$OUTPUT"
echo "| Location | Files | Purpose |" >> "$OUTPUT"
echo "|----------|-------|---------|" >> "$OUTPUT"
echo "| API Routes | $(echo "$API_ROUTES" | grep -v '^$' | wc -l | tr -d ' ') | Server-side enforcement (billing, limits) |" >> "$OUTPUT"
echo "| Components | $(echo "$COMPONENTS" | grep -v '^$' | wc -l | tr -d ' ') | UI display (upgrade prompts, limit bars) |" >> "$OUTPUT"
echo "| Hooks | $(echo "$HOOKS" | grep -v '^$' | wc -l | tr -d ' ') | Client-side state (subscription, usage) |" >> "$OUTPUT"
echo "| Lib | $(echo "$LIB" | grep -v '^$' | wc -l | tr -d ' ') | Shared logic (tier config, pricing) |" >> "$OUTPUT"
echo "| Pages | $(echo "$PAGES" | grep -v '^$' | wc -l | tr -d ' ') | Page-level access control |" >> "$OUTPUT"
echo "| Types | $(echo "$TYPES" | grep -v '^$' | wc -l | tr -d ' ') | Type definitions |" >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo "---" >> "$OUTPUT"
echo "" >> "$OUTPUT"
echo "Run \`bash ~/.hydra/tools/audit-feature-gates.sh\` to regenerate." >> "$OUTPUT"

echo ""
echo "Feature gate map written to: $OUTPUT"
echo "  Files with gates: $FILE_COUNT"
echo "  Total references: $MATCH_COUNT"
