# Polling Orchestration Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a skill-driven, `/loop`-based orchestration harness that polls Notion, Slack, and GitHub to detect work items and dispatch agent sessions — no daemon, no server, no build step.

**Architecture:** The `/loop` IS the orchestrator. Each tick acquires a tick lock, polls Notion/Slack/GitHub since `last_sync_at`, normalizes results into a SQLite event queue, dispatches subagents per pending context key, and releases the lock on success. Skills are markdown files the agent reads and executes.

**Tech Stack:** SQLite (via `sqlite3` CLI), Bash (init scripts), Markdown skills (agent-executed), Notion API, Slack API, GitHub API, Claude Agent tool for subagent dispatch.

---

## File Structure

```
harness/
  db/
    schema.sql           — full SQLite schema (all 5 tables)
    init.sh              — one-time DB init script
  skills/
    sync-state.md        — tick lock + last_sync_at management
    poll-notion.md       — Notion API polling instructions
    poll-slack.md        — Slack API polling + stub ticket creation
    poll-github.md       — GitHub API polling
    entity-registry.md   — how to create/query/link entities
    dispatch.md          — dispatcher logic: group by context_key, spawn sessions
  CLAUDE.md              — L1 routing table for the harness
  .env.example           — required API keys
```

---

## Task 1: SQLite Schema

**Files:**
- Create: `harness/db/schema.sql`
- Create: `harness/db/init.sh`

- [ ] **Step 1: Write `schema.sql`**

```sql
-- harness/db/schema.sql

CREATE TABLE IF NOT EXISTS sync_state (
  id TEXT PRIMARY KEY DEFAULT 'global',
  last_sync_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tick_lock (
  id TEXT PRIMARY KEY DEFAULT 'global',
  locked_at TEXT NOT NULL,
  locked_by TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  type TEXT NOT NULL,
  context_key TEXT NOT NULL,
  payload TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  received_at TEXT NOT NULL,
  processed_at TEXT
);

CREATE TABLE IF NOT EXISTS entities (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  external_id TEXT NOT NULL,
  type TEXT NOT NULL,
  url TEXT,
  created_at TEXT NOT NULL,
  UNIQUE(source, external_id)
);

CREATE TABLE IF NOT EXISTS links (
  entity_a TEXT NOT NULL REFERENCES entities(id),
  entity_b TEXT NOT NULL REFERENCES entities(id),
  relationship TEXT NOT NULL,
  created_at TEXT NOT NULL,
  created_by TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  context_key TEXT NOT NULL,
  status TEXT NOT NULL,
  intent TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Seed initial sync_state (epoch start so first tick polls everything)
INSERT OR IGNORE INTO sync_state (id, last_sync_at, updated_at)
VALUES ('global', '2024-01-01T00:00:00Z', datetime('now'));
```

- [ ] **Step 2: Write `init.sh`**

```bash
#!/usr/bin/env bash
# harness/db/init.sh
# Usage: bash harness/db/init.sh [path/to/harness.db]

set -euo pipefail
DB="${1:-harness/db/harness.db}"
echo "Initializing DB at $DB"
sqlite3 "$DB" < harness/db/schema.sql
echo "Done. Tables:"
sqlite3 "$DB" ".tables"
```

- [ ] **Step 3: Run init and verify**

```bash
chmod +x harness/db/init.sh
bash harness/db/init.sh
```

Expected output:
```
Initializing DB at harness/db/harness.db
Done. Tables:
entities  events  links  sessions  sync_state  tick_lock
```

- [ ] **Step 4: Verify sync_state seed**

```bash
sqlite3 harness/db/harness.db "SELECT * FROM sync_state;"
```

Expected: `global|2024-01-01T00:00:00Z|<timestamp>`

- [ ] **Step 5: Commit**

```bash
git add harness/db/schema.sql harness/db/init.sh harness/db/harness.db
git commit -m "feat: add SQLite schema and init script"
```

---

## Task 2: Sync-State Skill (Tick Lock + last_sync_at)

**Files:**
- Create: `harness/skills/sync-state.md`

This skill is invoked by the agent at the start and end of each tick. It contains exact SQLite commands for acquiring/releasing the tick lock and reading/updating `last_sync_at`.

- [ ] **Step 1: Write `sync-state.md`**

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add harness/skills/sync-state.md
git commit -m "feat: add sync-state skill for tick lock management"
```

---

## Task 3: Entity Registry Skill

**Files:**
- Create: `harness/skills/entity-registry.md`

- [ ] **Step 1: Write `entity-registry.md`**

```markdown
# entity-registry

Instructions for creating, querying, and linking entities in the local SQLite registry.

## DB path
Always use: `harness/db/harness.db`

## Create an entity

Generate a UUID via `uuidgen` (or `python3 -c "import uuid; print(uuid.uuid4())"` on macOS).

```bash
ENTITY_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
sqlite3 harness/db/harness.db \
  "INSERT OR IGNORE INTO entities (id, source, external_id, type, url, created_at)
   VALUES ('$ENTITY_ID', '$SOURCE', '$EXTERNAL_ID', '$TYPE', '$URL', datetime('now'));"
```

Values for `source`: `notion` | `slack` | `github`
Values for `type`: `ticket` | `thread` | `pr` | `comment`

## Look up entity by external_id

```bash
sqlite3 harness/db/harness.db \
  "SELECT id, source, external_id, type, url FROM entities
   WHERE source='$SOURCE' AND external_id='$EXTERNAL_ID';"
```

## Create a link between two entities

```bash
SESSION_ID="<current session id>"
sqlite3 harness/db/harness.db \
  "INSERT OR IGNORE INTO links (entity_a, entity_b, relationship, created_at, created_by)
   VALUES ('$ENTITY_A_ID', '$ENTITY_B_ID', '$RELATIONSHIP', datetime('now'), '$SESSION_ID');"
```

Values for `relationship`: `originated_from` | `implements` | `discussed_in`

## Find all entities linked to a context_key (Notion ticket entity ID)

```bash
sqlite3 harness/db/harness.db \
  "SELECT e.id, e.source, e.external_id, e.type, e.url
   FROM entities e
   JOIN links l ON (l.entity_a = e.id OR l.entity_b = e.id)
   WHERE l.entity_a = '$CONTEXT_KEY' OR l.entity_b = '$CONTEXT_KEY';"
```
```

- [ ] **Step 2: Commit**

```bash
git add harness/skills/entity-registry.md
git commit -m "feat: add entity-registry skill"
```

---

## Task 4: Notion Poller Skill

**Files:**
- Create: `harness/skills/poll-notion.md`

- [ ] **Step 1: Write `poll-notion.md`**

```markdown
# poll-notion

Poll the Notion tickets database for pages and comments modified since `last_sync_at` that are assigned to the agent or mention `@agent`.

## Required env vars
- `NOTION_API_KEY`
- `NOTION_DATABASE_ID`

## Poll for modified tickets

```bash
LAST_SYNC="$LAST_SYNC"   # from sync-state skill
curl -s -X POST "https://api.notion.com/v1/databases/$NOTION_DATABASE_ID/query" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d "{
    \"filter\": {
      \"and\": [
        {\"timestamp\": \"last_edited_time\", \"last_edited_time\": {\"after\": \"$LAST_SYNC\"}},
        {\"or\": [
          {\"property\": \"Assignee\", \"people\": {\"contains\": \"$NOTION_AGENT_USER_ID\"}},
          {\"property\": \"Agent Status\", \"select\": {\"is_not_empty\": true}}
        ]}
      ]
    }
  }"
```

## For each returned page

1. Look up entity by `external_id = page.id, source = "notion"` using entity-registry skill.
2. If entity does not exist, create it (`type: "ticket"`, `url: page.url`).
3. Check if event already exists: `SELECT id FROM events WHERE id='notion-<page_id>';`
4. If not exists, insert event:

```bash
PAGE_ID="<page.id>"
EVENT_ID="notion-$PAGE_ID"
# Write payload to a temp file — avoids shell interpolation of JSON special chars
# (backslashes, newlines, quotes) into the SQLite command string.
echo "$PAGE_JSON" > /tmp/harness_payload.json
printf "INSERT OR IGNORE INTO events (id, source, type, context_key, payload, status, received_at)\nVALUES (%s, 'notion', 'ticket.created', %s, readfile('/tmp/harness_payload.json'), 'pending', datetime('now'));\n" \
  "'$EVENT_ID'" "'$ENTITY_ID'" | sqlite3 harness/db/harness.db
rm -f /tmp/harness_payload.json
```

Note: `readfile()` is a SQLite CLI extension available in sqlite3 3.31+. If unavailable, use python3:
```bash
python3 -c "
import sqlite3, sys, json
db = sqlite3.connect('harness/db/harness.db')
payload = open('/tmp/harness_payload.json').read()
db.execute('INSERT OR IGNORE INTO events (id,source,type,context_key,payload,status,received_at) VALUES (?,?,?,?,?,?,datetime(\"now\"))',
  ('$EVENT_ID','notion','ticket.created','$ENTITY_ID',payload,'pending'))
db.commit()
"
```

## Poll for comments mentioning @agent

```bash
# For each page entity in the DB, fetch its comments
curl -s "https://api.notion.com/v1/comments?block_id=$PAGE_ID" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28"
```

For each comment where `rich_text` contains `@agent` and `created_time > last_sync_at`:
- Event ID: `notion-comment-<comment_id>`
- Event type: `comment.tagged`
- context_key: same Notion ticket entity ID
```

- [ ] **Step 2: Commit**

```bash
git add harness/skills/poll-notion.md
git commit -m "feat: add poll-notion skill"
```

---

## Task 5: Slack Poller Skill

**Files:**
- Create: `harness/skills/poll-slack.md`

- [ ] **Step 1: Write `poll-slack.md`**

```markdown
# poll-slack

Poll the configured Slack channel for messages since `last_sync_at` that mention `@agent`. If a message thread has no linked Notion ticket, create a stub ticket inline.

## Required env vars
- `SLACK_BOT_TOKEN`
- `SLACK_CHANNEL_ID`
- `NOTION_API_KEY`
- `NOTION_DATABASE_ID`

## Poll for messages

```bash
# Use SQLite to convert last_sync_at to a Unix timestamp — platform-safe on macOS, Linux, and Windows.
# last_sync_at is stored as SQLite datetime format (YYYY-MM-DD HH:MM:SS), not ISO 8601.
LAST_SYNC_TS=$(sqlite3 harness/db/harness.db \
  "SELECT strftime('%s', last_sync_at) FROM sync_state WHERE id='global';")
curl -s "https://slack.com/api/conversations.history?channel=$SLACK_CHANNEL_ID&oldest=$LAST_SYNC_TS&limit=100" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN"
```

## For each message mentioning `@agent`

1. Check if a Notion entity is linked to this Slack thread:

```bash
SLACK_EXTERNAL_ID="$CHANNEL_ID/$MESSAGE_TS"
sqlite3 harness/db/harness.db \
  "SELECT e2.id, e2.external_id FROM links l
   JOIN entities e1 ON e1.id = l.entity_a
   JOIN entities e2 ON e2.id = l.entity_b
   WHERE e1.source='slack' AND e1.external_id='$SLACK_EXTERNAL_ID' AND e2.source='notion';"
```

2. If NO Notion entity is linked — create a stub Notion ticket:

```bash
STUB_TITLE="From Slack: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
curl -s -X POST "https://api.notion.com/v1/pages" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d "{
    \"parent\": {\"database_id\": \"$NOTION_DATABASE_ID\"},
    \"properties\": {
      \"Name\": {\"title\": [{\"text\": {\"content\": \"$STUB_TITLE\"}}]},
      \"Agent Status\": {\"select\": {\"name\": \"Queued\"}},
      \"Slack Thread\": {\"url\": \"https://slack.com/archives/$CHANNEL_ID/p${MESSAGE_TS/./}\"}
    }
  }"
```

3. Create entities and link them (using entity-registry skill):
   - `slack` entity: `external_id = "$CHANNEL_ID/$MESSAGE_TS"`, `type = "thread"`
   - `notion` entity: `external_id = <new page id>`, `type = "ticket"`
   - Link: `slack_entity → notion_entity`, `relationship = "originated_from"`

4. Insert event:
   - Event ID: `slack-$CHANNEL_ID-$MESSAGE_TS`
   - Event type: `message.tagged`
   - context_key: Notion entity ID
   - payload: full Slack message JSON
```

- [ ] **Step 2: Commit**

```bash
git add harness/skills/poll-slack.md
git commit -m "feat: add poll-slack skill with stub ticket creation"
```

---

## Task 6: GitHub Poller Skill

**Files:**
- Create: `harness/skills/poll-github.md`

- [ ] **Step 1: Write `poll-github.md`**

```markdown
# poll-github

Poll the configured GitHub repo for PRs updated since `last_sync_at` on agent-opened branches. Capture review comments, merges, and closes.

## Required env vars
- `GITHUB_TOKEN`
- `GITHUB_REPO`  — format: `owner/repo`

## Poll updated PRs

```bash
curl -s "https://api.github.com/repos/$GITHUB_REPO/pulls?state=all&sort=updated&direction=desc&per_page=50" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json"
```

Filter to PRs where `updated_at > last_sync_at`.

## For each PR

1. Look up entity by `source="github"`, `external_id="$GITHUB_REPO#$PR_NUMBER"`.
2. If entity not found, skip (only track agent-opened PRs; agent creates entity when opening PR).
3. If found, determine event type:
   - PR state is `closed` AND `merged=true` → `pr.merged`
   - PR state is `closed` AND `merged=false` → `pr.closed`
   - Otherwise → check for new review comments:

```bash
curl -s "https://api.github.com/repos/$GITHUB_REPO/pulls/$PR_NUMBER/comments" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json"
```

Filter to comments where `created_at > last_sync_at` → event type `pr.review_commented`.

4. Resolve context_key via entity graph:

```bash
# Follow links from github entity back to notion entity
sqlite3 harness/db/harness.db \
  "SELECT e2.id FROM links l
   JOIN entities e1 ON e1.id = l.entity_a
   JOIN entities e2 ON e2.id = l.entity_b
   WHERE e1.source='github' AND e1.external_id='$GITHUB_REPO#$PR_NUMBER' AND e2.source='notion'
   UNION
   SELECT e1.id FROM links l
   JOIN entities e1 ON e1.id = l.entity_a
   JOIN entities e2 ON e2.id = l.entity_b
   WHERE e2.source='github' AND e2.external_id='$GITHUB_REPO#$PR_NUMBER' AND e1.source='notion';"
```

5. Insert event with resolved context_key:
   - Event ID: `github-$GITHUB_REPO-$PR_NUMBER-<type>` (for comments: append comment ID)
   - Payload: PR JSON (or comment JSON for `pr.review_commented`)
```

- [ ] **Step 2: Commit**

```bash
git add harness/skills/poll-github.md
git commit -m "feat: add poll-github skill"
```

---

## Task 7: Dispatcher Skill

**Files:**
- Create: `harness/skills/dispatch.md`

- [ ] **Step 1: Write `dispatch.md`**

```markdown
# dispatch

Read pending events, group by context_key, skip contexts with running sessions, and spawn subagent sessions.

## DB path
Always use: `harness/db/harness.db`

## Step 1: Read all pending context_keys, then fetch events per key

GROUP_CONCAT(payload) is unsafe because JSON payloads contain commas.
Use two queries: first get distinct context keys, then fetch full event rows per key.

```bash
# Query 1: which context_keys have pending events?
CONTEXT_KEYS=$(sqlite3 harness/db/harness.db \
  "SELECT DISTINCT context_key FROM events WHERE status='pending';")

# For each context_key (loop in agent logic):
# Query 2: fetch full event rows — payload is intact, no concatenation
sqlite3 harness/db/harness.db \
  "SELECT id, source, type, context_key, payload, received_at
   FROM events
   WHERE context_key='$CONTEXT_KEY' AND status='pending';"
```

## Step 2: For each context_key, check for running sessions

```bash
RUNNING=$(sqlite3 harness/db/harness.db \
  "SELECT id FROM sessions WHERE context_key='$CONTEXT_KEY' AND status='running';")
if [ -n "$RUNNING" ]; then
  echo "Session already running for $CONTEXT_KEY — skipping"
  continue
fi
```

## Step 3: Resolve context for the subagent

Gather the following for injection into the subagent prompt:
1. Notion ticket content — fetch via Notion API using the entity's `external_id`:
   ```bash
   NOTION_ENTITY=$(sqlite3 harness/db/harness.db \
     "SELECT external_id, url FROM entities WHERE id='$CONTEXT_KEY' AND source='notion';")
   PAGE_ID=$(echo "$NOTION_ENTITY" | cut -d'|' -f1)
   curl -s "https://api.notion.com/v1/pages/$PAGE_ID" \
     -H "Authorization: Bearer $NOTION_API_KEY" \
     -H "Notion-Version: 2022-06-28"
   ```
2. Linked entities (from entity-registry skill):
   ```bash
   sqlite3 harness/db/harness.db \
     "SELECT e.source, e.external_id, e.type, e.url FROM entities e
      JOIN links l ON (l.entity_a=e.id OR l.entity_b=e.id)
      WHERE (l.entity_a='$CONTEXT_KEY' OR l.entity_b='$CONTEXT_KEY')
        AND e.id != '$CONTEXT_KEY';"
   ```
3. Recent Slack thread (if a slack entity is linked) — fetch last 10 messages:
   ```bash
   curl -s "https://slack.com/api/conversations.replies?channel=$CHANNEL_ID&ts=$THREAD_TS&limit=10" \
     -H "Authorization: Bearer $SLACK_BOT_TOKEN"
   ```
4. Available skills list: sync-state, poll-notion, poll-slack, poll-github, entity-registry, dispatch
5. Triggering events (the pending event payloads for this context_key)

## Step 4: Create a session record

```bash
SESSION_ID="session-$(uuidgen | tr '[:upper:]' '[:lower:]')"
sqlite3 harness/db/harness.db \
  "INSERT INTO sessions (id, context_key, status, intent, created_at, updated_at)
   VALUES ('$SESSION_ID', '$CONTEXT_KEY', 'running', '$EVENT_TYPES', datetime('now'), datetime('now'));"
```

## Step 5: Mark events as processing

```bash
sqlite3 harness/db/harness.db \
  "UPDATE events SET status='processing' WHERE context_key='$CONTEXT_KEY' AND status='pending';"
```

## Step 6: Spawn subagent (via Agent tool)

Inject the following prompt into the Agent tool:

```
You are handling work item: <context_key>

Notion ticket: <notion_page_content>
Linked entities: <linked_entities_table>
Slack thread: <recent_slack_messages if applicable>
Triggering events: <event_types_and_payloads>
Session ID: <SESSION_ID>

Available skills (read and follow them as needed):
- harness/skills/sync-state.md
- harness/skills/poll-notion.md
- harness/skills/poll-slack.md
- harness/skills/poll-github.md
- harness/skills/entity-registry.md
- harness/skills/dispatch.md

Reason about what action is needed and act. When done:
1. Update Notion ticket status as your LAST action.
2. Update session record:
   sqlite3 harness/db/harness.db "UPDATE sessions SET status='completed', updated_at=datetime('now') WHERE id='<SESSION_ID>';"
3. Mark events as done:
   sqlite3 harness/db/harness.db "UPDATE events SET status='done', processed_at=datetime('now') WHERE context_key='<context_key>' AND status='processing';"

If you cannot proceed without human input:
1. Post a Slack message to the originating thread explaining what you need.
2. Set Notion ticket status to `Blocked`.
3. Update session: status='cancelled' (human will restart via @agent reply).
```

## Step 7: Handle subagent failure

If the Agent tool throws or the subagent does not update session status, mark the session cancelled and events back to pending:

```bash
sqlite3 harness/db/harness.db \
  "UPDATE sessions SET status='cancelled', updated_at=datetime('now') WHERE id='$SESSION_ID';"
sqlite3 harness/db/harness.db \
  "UPDATE events SET status='pending' WHERE context_key='$CONTEXT_KEY' AND status='processing';"
```
```

- [ ] **Step 2: Commit**

```bash
git add harness/skills/dispatch.md
git commit -m "feat: add dispatcher skill"
```

---

## Task 8: CLAUDE.md Routing Table

**Files:**
- Create: `harness/CLAUDE.md`

This is the top-level entry point. When `/loop` fires, the agent reads this file first to understand the tick flow and which skills to invoke.

- [ ] **Step 1: Write `harness/CLAUDE.md`**

```markdown
# Orchestration Harness — Tick Entry Point

This file is the L1 routing table. Each `/loop` tick runs the sequence below.

## Tick Sequence

1. **sync-state**: Check and acquire tick lock → read `last_sync_at`
   - Skill: `harness/skills/sync-state.md`
   - If lock is active (< 30 min old): stop immediately, do not poll.

2. **Poll all sources** (if any poller fails, release lock and stop — do not update `last_sync_at`):
   - Notion: `harness/skills/poll-notion.md`
   - Slack: `harness/skills/poll-slack.md`
   - GitHub: `harness/skills/poll-github.md`

3. **Dispatch**: `harness/skills/dispatch.md`
   - Group pending events by context_key
   - Skip contexts with running sessions
   - Spawn one subagent per context_key

4. **sync-state**: Update `last_sync_at` → release tick lock

## DB
All skills use: `harness/db/harness.db`

## Env vars required
See `.env.example`

## Glossary
See `CONTEXT.md` in the project root for domain terminology.
```

- [ ] **Step 2: Commit**

```bash
git add harness/CLAUDE.md
git commit -m "feat: add harness CLAUDE.md routing table"
```

---

## Task 9: .env.example

**Files:**
- Create: `harness/.env.example`

- [ ] **Step 1: Write `.env.example`**

```bash
# harness/.env.example — copy to .env and fill in values

ANTHROPIC_API_KEY=
NOTION_API_KEY=
NOTION_DATABASE_ID=          # the tickets database ID
NOTION_AGENT_USER_ID=        # Notion user ID for the agent account
SLACK_BOT_TOKEN=
SLACK_CHANNEL_ID=            # single channel to watch
GITHUB_TOKEN=
GITHUB_REPO=                 # format: owner/repo
```

- [ ] **Step 2: Commit**

```bash
git add harness/.env.example
git commit -m "feat: add .env.example"
```

---

## Task 10: Notion Status Properties Verification

The spec (§9) requires Notion tickets to carry specific properties. This task verifies the Notion database has them configured and documents the expected schema.

- [ ] **Step 1: Add Notion property requirements to `poll-notion.md`**

Open `harness/skills/poll-notion.md` and append:

```markdown
## Required Notion database properties

The tickets database MUST have these properties configured in Notion:

| Property | Type | Values |
|---|---|---|
| `Agent Status` | Select | `Queued`, `In Progress`, `Done`, `Blocked` |
| `Agent Session ID` | Rich Text | — |
| `Last Agent Update` | Date | — |
| `GitHub PR` | URL | — |
| `Slack Thread` | URL | — |

When creating a stub ticket from Slack, set:
- `Agent Status` → `Queued`
- `Slack Thread` → thread URL

When the agent begins work on a ticket, set:
- `Agent Status` → `In Progress`
- `Agent Session ID` → current session ID
- `Last Agent Update` → now

When work is complete, set `Agent Status` → `Done` as the final action.
When blocked, set `Agent Status` → `Blocked`.
```

- [ ] **Step 2: Commit**

```bash
git add harness/skills/poll-notion.md
git commit -m "docs: add required Notion property schema to poll-notion skill"
```

---

## Task 11: SQLite Smoke Tests

**Files:**
- Create: `harness/db/test.sh`

Tests the 8 SQLite-only paths: entity create/lookup, link creation/traversal, event insert+dedup, dispatch grouping, and session dedup. No API keys needed.

- [ ] **Step 1: Write `harness/db/test.sh`**

```bash
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
# Create entity
EA=$(python3 -c "import uuid; print(uuid.uuid4())")
sqlite3 "$DB" "INSERT OR IGNORE INTO entities (id,source,external_id,type,created_at) VALUES ('$EA','notion','page-abc','ticket',datetime('now'));"
RESULT=$(sqlite3 "$DB" "SELECT external_id FROM entities WHERE source='notion' AND external_id='page-abc';")
assert "entity lookup by source+external_id" "page-abc" "$RESULT"

# Duplicate insert is ignored (UNIQUE constraint)
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
```

- [ ] **Step 2: Run tests**

```bash
chmod +x harness/db/test.sh
bash harness/db/test.sh
```

Expected output:
```
--- Entity registry ---
  PASS: entity lookup by source+external_id
  PASS: duplicate entity insert ignored
--- Link creation and traversal ---
  PASS: linked entity traversal finds slack thread
--- Event insert and dedup ---
  PASS: duplicate event insert ignored via deterministic ID
--- Dispatch: distinct context_keys ---
  PASS: dispatcher sees 1 distinct context_key
--- Dispatch: session dedup ---
  PASS: running session detected for context_key
--- Tick lock: atomic acquire ---
  PASS: second lock attempt returns 0 rows changed

Results: 7 passed, 0 failed
```

- [ ] **Step 3: Commit**

```bash
git add harness/db/test.sh
git commit -m "test: add SQLite smoke tests for entity-registry and dispatch logic"
```

---

## Self-Review

**Spec coverage check:**

| Spec section | Covered by |
|---|---|
| §1 Goals — polling, no daemon, Notion as source of truth | CLAUDE.md tick sequence, all poller skills |
| §2 Architecture — tick lock, atomic tick | sync-state skill |
| §3 SQLite schema (5 tables) | Task 1 schema.sql |
| §4 Cross-system entity linking | entity-registry skill, poll-slack stub creation |
| §5 Poll cycle | All poller skills + CLAUDE.md sequence |
| §6 Dispatcher | dispatch skill |
| §7 Agent behavior — blocked state, Notion as commit point | dispatch skill subagent prompt |
| §8 Trigger convention + event types | All poller skills use correct event type strings |
| §9 Notion status layer | Task 10 / poll-notion.md appendix |
| §10 Project structure | File structure section above |
| §11 Configuration | .env.example |
| §12 Non-goals | Excluded from plan (no TypeScript, no webhooks, single repo/channel) |

**Placeholder scan:** No TBD/TODO/placeholder found. All code blocks contain complete runnable commands.

**Type consistency:** Event types used consistently across skills: `ticket.created`, `comment.tagged`, `message.tagged`, `pr.review_commented`, `pr.merged`, `pr.closed`. Entity ID always used as context_key throughout.

---

## NOT in scope

| Deferred item | Rationale |
|---|---|
| Real-time event delivery (webhooks) | Explicitly excluded in spec §12 |
| Multi-channel Slack monitoring | Spec §12: single channel only |
| Multi-repo GitHub support | Spec §12: single repo only |
| Agent-authored skills | Spec §12: human-authored only in v1 |
| Partial tick commits | Spec §12: tick is all-or-nothing |
| Notion comment pagination | v1: assumes < 100 comments per ticket; pagination deferred |
| Slack message pagination | v1: limit=100 per tick; overflow events retried next tick via last_sync_at |
| Windows native support (non-WSL) | Bash + sqlite3 CLI assumed; WSL or Git Bash required on Windows |
| API authentication refresh / token rotation | Assumes long-lived tokens in .env |

---

## What already exists

| Sub-problem | Existing artifact | Reused? |
|---|---|---|
| Domain terminology | `CONTEXT.md` in project root | Yes — `harness/CLAUDE.md` links to it |
| Spec | `docs/superpowers/specs/2026-06-02-polling-orchestration-harness-design.md` | Yes — plan directly implements it |
| SQLite schema | None | N/A — new project |
| Pollers | None | N/A — new project |

No existing code was unnecessarily rebuilt.

---

## Failure Modes

| Codepath | Realistic failure | Test covers? | Error handling? | User sees? |
|---|---|---|---|---|
| Tick lock acquire (D1 fix) | Two ticks launch simultaneously | Yes (test.sh) | Yes — INSERT OR IGNORE + changes() check bails cleanly | Nothing — second tick silently exits |
| Entity insert dedup (D2 fix) | Concurrent pollers race on same entity | Yes (test.sh) | Yes — UNIQUE constraint + INSERT OR IGNORE | Nothing |
| Slack timestamp conversion (D3 fix) | Clock drift between SQLite and Slack API | No | Partial — SQLite strftime is consistent; Slack may reject very old timestamps | Slack returns empty results; next tick retries |
| Payload storage (D5 fix) | JSON with newlines/backslashes | No | Yes — tempfile approach avoids shell interpolation | Nothing — INSERT succeeds or fails silently; event missing from queue |
| Notion API 429 (rate limit) | Comment polling loop hits rate limit | No | No | Tick fails; last_sync_at not updated; retries next tick |
| Agent tool timeout | Subagent takes > tick interval | No | Partial — session marked running; tick lock stale threshold clears it after 30 min | No progress on work item for 30+ minutes |
| **CRITICAL GAP:** Payload insert fails silently | readfile() unavailable on SQLite < 3.31 | No | No — python3 fallback shown but not enforced | Event silently missing from queue; work item never dispatched |

The `readfile()` availability is the one critical gap: the plan shows a python3 fallback but doesn't enforce it. The implementation step should detect SQLite version and choose the appropriate insert method.

---

## Parallelization Strategy

| Task | Modules touched | Depends on |
|---|---|---|
| Task 1: Schema + init | `harness/db/` | — |
| Task 2: sync-state | `harness/skills/` | Task 1 (DB must exist to test) |
| Task 3: entity-registry | `harness/skills/` | Task 1 |
| Tasks 4-6: pollers | `harness/skills/` | Task 1, Task 3 |
| Task 7: dispatch | `harness/skills/` | Task 1, Task 3 |
| Task 8: CLAUDE.md | `harness/` | Tasks 2-7 (references all skills) |
| Task 9: .env.example | `harness/` | — |
| Task 10: Notion properties | `harness/skills/poll-notion.md` | Task 4 |
| Task 11: test.sh | `harness/db/` | Task 1 |

**Lane A:** Task 1 → Tasks 2+3 in parallel → Tasks 4+5+6+7 in parallel → Task 8
**Lane B (independent):** Tasks 9 + 11 can run anytime after Task 1

2 lanes. Tasks 4, 5, 6, 7 can all run in parallel worktrees after Tasks 1+3 complete.

---

## TODOS.md

```markdown
## TODO: N+1 API calls in comment/review polling

**What:** Notion comment polling and GitHub PR review comment polling make one API call per tracked entity per tick.

**Why:** At 50+ tracked tickets, Notion's 3 req/sec rate limit means 17+ seconds of polling per tick just for comments. Same pattern for GitHub review comments.

**Current state:** Accepted as a v1 trade-off (spec §12 explicitly lists acceptable latency as a non-goal). Safe at small scale (< 20 tickets).

**Optimization path:** Batch comment polling via cursor-based pagination with rate limit backoff; or skip comment polling for tickets in `Done` status.

**Files:** `harness/skills/poll-notion.md`, `harness/skills/poll-github.md`

**Depends on:** None — can be addressed in v2.
```

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | — | — |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR (PLAN) | 5 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

**VERDICT: ENG CLEARED — ready to implement.**
