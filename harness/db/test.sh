#!/usr/bin/env bash
# harness/db/test.sh — smoke test all SQLite logic without live API calls
set -euo pipefail
DB="/tmp/harness_test_$$.db"
trap "rm -f $DB" EXIT
sqlite3 "$DB" < harness/db/schema.sql
PASS=0; FAIL=0

assert() {
  local desc="$1"; local expected="$2"; local actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $desc"; PASS=$((PASS+1))
  else
    echo "  FAIL: $desc (expected '$expected', got '$actual')"; FAIL=$((FAIL+1))
  fi
}

echo "--- Entity registry ---"
EA=$(python3 -c "import uuid; print(uuid.uuid4())")
sqlite3 "$DB" "INSERT OR IGNORE INTO entities (id,source,external_id,type,created_at) VALUES ('$EA','notion','page-abc','ticket',datetime('now'));"
RESULT=$(sqlite3 "$DB" "SELECT external_id FROM entities WHERE source='notion' AND external_id='page-abc';")
assert "entity lookup by source+external_id" "page-abc" "$RESULT"

sqlite3 "$DB" "INSERT OR IGNORE INTO entities (id,source,external_id,type,created_at) VALUES ('other-uuid','notion','page-abc','ticket',datetime('now'));"
COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM entities WHERE external_id='page-abc';")
assert "duplicate entity insert ignored" "1" "$COUNT"

echo "--- Link creation and traversal ---"
EB=$(python3 -c "import uuid; print(uuid.uuid4())")
sqlite3 "$DB" "INSERT OR IGNORE INTO entities (id,source,external_id,type,created_at) VALUES ('$EB','slack','C123/1234','thread',datetime('now'));"
sqlite3 "$DB" "INSERT OR IGNORE INTO links (entity_a,entity_b,relationship,created_at,created_by) VALUES ('$EB','$EA','originated_from',datetime('now'),'test');"
LINKED=$(sqlite3 "$DB" "SELECT e.external_id FROM entities e JOIN links l ON (l.entity_a=e.id OR l.entity_b=e.id) WHERE (l.entity_a='$EA' OR l.entity_b='$EA') AND e.id != '$EA';")
assert "linked entity traversal finds slack thread" "C123/1234" "$LINKED"

echo "--- Event insert and dedup ---"
sqlite3 "$DB" "INSERT OR IGNORE INTO events (id,source,type,context_key,payload,status,received_at) VALUES ('notion-page-abc','notion','ticket.created','$EA','{}','pending',datetime('now'));"
sqlite3 "$DB" "INSERT OR IGNORE INTO events (id,source,type,context_key,payload,status,received_at) VALUES ('notion-page-abc','notion','ticket.created','$EA','{}','pending',datetime('now'));"
ECOUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE id='notion-page-abc';")
assert "duplicate event insert ignored via deterministic ID" "1" "$ECOUNT"

echo "--- Dispatch: distinct context_keys ---"
sqlite3 "$DB" "INSERT OR IGNORE INTO events (id,source,type,context_key,payload,status,received_at) VALUES ('slack-C123-456','slack','message.tagged','$EA','{}','pending',datetime('now'));"
KEYS=$(sqlite3 "$DB" "SELECT COUNT(DISTINCT context_key) FROM events WHERE status='pending';")
assert "dispatcher sees 1 distinct context_key" "1" "$KEYS"

echo "--- Dispatch: session dedup ---"
SID=$(python3 -c "import uuid; print(uuid.uuid4())")
sqlite3 "$DB" "INSERT INTO sessions (id,context_key,status,created_at,updated_at) VALUES ('$SID','$EA','running',datetime('now'),datetime('now'));"
RUNNING=$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE context_key='$EA' AND status='running';")
assert "running session detected for context_key" "1" "$RUNNING"

echo "--- Tick lock: atomic acquire ---"
sqlite3 "$DB" "INSERT OR IGNORE INTO tick_lock (id,locked_at,locked_by) VALUES ('global',datetime('now'),'tick-1');"
ROWS=$(sqlite3 "$DB" "INSERT OR IGNORE INTO tick_lock (id,locked_at,locked_by) VALUES ('global',datetime('now'),'tick-2'); SELECT changes();")
assert "second lock attempt returns 0 rows changed" "0" "$ROWS"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
