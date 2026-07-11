# sync-state

Instructions for managing tick lock and last_sync_at.

## DB path
Always use: `harness/db/harness.db`

## Check and acquire tick lock

Run this sequence. It uses atomic SQLite operations to avoid the check-then-act race condition.

```bash
# Step 1: Clear stale lock if older than 30 minutes (platform-safe via SQLite strftime)
sqlite3 harness/db/harness.db \
  "DELETE FROM tick_lock WHERE id='global'
     AND (strftime('%s','now') - strftime('%s', locked_at)) > 1800;"

# Step 2: Attempt atomic insert. If another tick already holds the lock, INSERT OR IGNORE
# writes 0 rows — we check changes() to detect this and bail cleanly.
TICK_ID="tick-$(date -u +%Y%m%dT%H%M%SZ)-$$"
ROWS=$(sqlite3 harness/db/harness.db \
  "INSERT OR IGNORE INTO tick_lock (id, locked_at, locked_by)
     VALUES ('global', datetime('now'), '$TICK_ID');
   SELECT changes();")
if [ "$ROWS" -eq 0 ]; then
  echo "Tick already running. Bailing."
  exit 0
fi
echo "Lock acquired: $TICK_ID"
```

## Read last_sync_at

```bash
LAST_SYNC=$(sqlite3 harness/db/harness.db "SELECT last_sync_at FROM sync_state WHERE id='global';")
echo "Polling since: $LAST_SYNC"
```

## Update last_sync_at (call ONLY on successful tick completion)

```bash
sqlite3 harness/db/harness.db \
  "UPDATE sync_state SET last_sync_at=datetime('now'), updated_at=datetime('now') WHERE id='global';"
```

## Release tick lock (call at tick end — success OR failure)

```bash
sqlite3 harness/db/harness.db "DELETE FROM tick_lock WHERE id='global';"
echo "Lock released."
```
