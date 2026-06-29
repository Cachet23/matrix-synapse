#!/bin/bash
# Matrix Synapse Backup Script
# Run daily via cron
#
# Usage: Set BACKUP_DIR and DATA_DIR to your paths, then cron it.

set -euo pipefail

# ── Config ──────────────────────────────────────────────
BACKUP_DIR="${BACKUP_DIR:-./backups}"
DATA_DIR="${DATA_DIR:-./synapse-data}"
# ────────────────────────────────────────────────────────

DATE=$(date +%Y-%m-%d)
BACKUP_PATH="$BACKUP_DIR/synapse-$DATE"

mkdir -p "$BACKUP_PATH"

echo "[$(date)] Starting Synapse backup..."

# 1. PostgreSQL dump
echo "  Dumping PostgreSQL..."
docker exec synapse-db pg_dump -U synapse synapse > "$BACKUP_PATH/synapse-db.sql"

# 2. Media store + signing keys + config
echo "  Copying data..."
cp -r "$DATA_DIR" "$BACKUP_PATH/synapse-data"

# 3. Compress and encrypt with AES256-GPG
echo "  Compressing and encrypting..."
tar -czf - -C "$BACKUP_PATH" . | gpg --symmetric --cipher-algo AES256 --batch --passphrase-file /etc/synapse-backup-key -o "$BACKUP_PATH.tar.gz.gpg"
rm -rf "$BACKUP_PATH"

# 4. Keep only last 7 days
find "$BACKUP_DIR" -name "synapse-*.tar.gz.gpg" -mtime +7 -delete

echo "[$(date)] Backup complete: $BACKUP_PATH.tar.gz.gpg ($(du -sh "$BACKUP_PATH.tar.gz.gpg" | cut -f1))"
