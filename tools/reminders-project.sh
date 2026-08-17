#!/bin/bash
# reminders-project.sh — project the master todo's WRITTEN items into a native
# Apple Reminders list. This is a VIEW, never a source: add-if-absent (dedupe by
# name), so a tick in Reminders sticks and nothing churns. Derived deadline
# reminders (autopay, upcoming estimated-tax dates) are intentionally EXCLUDED —
# they clear when the underlying state resolves, not when you tick a box, so a
# checkbox is the wrong semantics for them. Source of truth stays the job sensors
# and the master reader. See memory project-every-job-sweeper-to-master-todo.
#
# Runs after the master is refreshed (todo-master-refresh.sh, 8:30). Needs macOS
# Automation permission to control Reminders (granted once, interactively).

MASTER_JSON="$HOME/.hydra/briefings/master-todo.json"
ASCRIPT="$HOME/.hydra/tools/reminders-add.applescript"
LIST="id8 / Master"
LOG="$HOME/Library/Logs/claude-automation/todo-master.log"

[ -f "$MASTER_JSON" ] || { echo "reminders-project: no master json" >> "$LOG"; exit 0; }
[ -f "$ASCRIPT" ] || { echo "reminders-project: missing $ASCRIPT" >> "$LOG"; exit 0; }

added=0; skipped=0; failed=0
while IFS=$'\t' read -r who title due; do
	[ -z "$title" ] && continue
	y=0; m=0; d=0
	if [ -n "$due" ]; then
		IFS=- read -r yy mm dd <<< "$due"
		y=$((10#${yy:-0})); m=$((10#${mm:-0})); d=$((10#${dd:-0}))
	fi
	body="From the id8 master todo — ${who}. Projection; the job's own list is the source of truth."
	res=$(osascript "$ASCRIPT" "$LIST" "[$who] $title" "$body" "$y" "$m" "$d" 2>>"$LOG")
	case "$res" in
		ADDED) added=$((added+1)) ;;
		SKIP)  skipped=$((skipped+1)) ;;
		*)     failed=$((failed+1)) ;;
	esac
done < <(jq -r '
	.items[] | select(.source=="written")
	# Strip the volatile countdown ("— due in Nd" / "— Nd overdue") so the reminder
	# NAME is stable day to day (dedupe-by-name holds); the timing lives in the
	# native due date, not the title. Otherwise the name changes daily and churns.
	| [(.who // .job // "?"),
	   (.title | gsub(" — (due in [0-9]+d|[0-9]+d overdue)"; "")),
	   (.dueOn // "")] | @tsv
' "$MASTER_JSON" 2>/dev/null)

msg="reminders-project: +$added new, $skipped existing, $failed failed -> \"$LIST\""
echo "$msg" | tee -a "$LOG"
[ "$failed" -gt 0 ] && echo "  (failures usually = Automation permission not yet granted for Reminders)" | tee -a "$LOG"
exit 0
