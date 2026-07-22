#!/bin/bash
# ID8Labs LLC - Weekly Document Backup
# Runs every Sunday at 2 AM

SOURCE="$HOME/Documents/ID8Labs-LLC"
DEST="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups/ID8Labs-LLC"
# Log lives OFF iCloud: writing the log to the iCloud-synced SOURCE tripped
# `echo: write error: Resource deadlock avoided` (mmap EDEADLK) mid-sync and
# failed the job every week. A local log ends that class of fault entirely.
LOG_DIR="$HOME/Library/Logs/weekly-backup"
LOG_FILE="$LOG_DIR/backup-$(date +%Y).log"

mkdir -p "$DEST"
mkdir -p "$LOG_DIR"

echo "$(date): Starting weekly backup" >> "$LOG_FILE"

# Sync to iCloud (rsync preserves structure, only copies changed files)
rsync -av --delete --exclude 'Logs/' "$SOURCE/" "$DEST/" >> "$LOG_FILE" 2>&1
RSYNC_RC=$?

# Tend contract (TEND-CONTRACT.md): self-report so the Gardener reads this job
# by its own word, not by a launchd exit code. Weekly cadence -> 168h.
source "$HOME/.hydra/tools/tend-lib.sh" 2>/dev/null || true

if [ "$RSYNC_RC" -eq 0 ]; then
    echo "$(date): Backup completed successfully" >> "$LOG_FILE"
    tend_report weekly-backup GREEN "documents synced to iCloud" 168
else
    echo "$(date): Backup failed!" >> "$LOG_FILE"
    osascript -e 'display notification "Weekly backup failed! Check logs." with title "ID8Labs LLC - Backup Error"'
    tend_report weekly-backup RED "rsync to iCloud failed (rc $RSYNC_RC)" 168 \
        "weekly backup rsync failed (rc $RSYNC_RC)" "check iCloud sync + disk, then re-run the backup"
fi

echo "---" >> "$LOG_FILE"
