#!/bin/bash
# ID8Labs LLC - Weekly Document Backup
# Runs every Sunday at 2 AM

SOURCE="$HOME/Documents/ID8Labs-LLC"
DEST="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups/ID8Labs-LLC"
LOG_FILE="$SOURCE/Logs/backup-$(date +%Y).log"

mkdir -p "$DEST"
mkdir -p "$(dirname "$LOG_FILE")"

echo "$(date): Starting weekly backup" >> "$LOG_FILE"

# Sync to iCloud (rsync preserves structure, only copies changed files)
rsync -av --delete --exclude 'Logs/' "$SOURCE/" "$DEST/" >> "$LOG_FILE" 2>&1  # exclude Logs/: the live backup log churns during the run and trips mmap EDEADLK on iCloud

if [ $? -eq 0 ]; then
    echo "$(date): Backup completed successfully" >> "$LOG_FILE"
else
    echo "$(date): Backup failed!" >> "$LOG_FILE"
    osascript -e 'display notification "Weekly backup failed! Check logs." with title "ID8Labs LLC - Backup Error"'
fi

echo "---" >> "$LOG_FILE"
