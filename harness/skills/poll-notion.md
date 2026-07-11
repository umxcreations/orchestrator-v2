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
          {\"property\": \"Status\", \"status\": {\"is_not_empty\": true}}
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

## Required Notion database properties

The tickets database MUST have these properties configured in Notion:

| Property | Type | Values |
|---|---|---|
| `Status` | Status | `Not started`, `In progress`, `Done`, `Blocked`, `In review`, `Cancelled` |
| `Agent Session ID` | Rich Text | — |
| `Last Agent Update` | Date | — |
| `GitHub PR` | URL | — |
| `Slack Thread` | URL | — |

When creating a stub ticket from Slack, set:
- `Status` → `Not started`
- `Slack Thread` → thread URL

When the agent begins work on a ticket, set:
- `Status` → `In progress`
- `Agent Session ID` → current session ID
- `Last Agent Update` → now

When work is complete, set `Status` → `Done` as the final action.
When blocked, set `Status` → `Blocked`.

## Self-Improvement Notes (2026-06-04)

### Gap: Property name mismatch caused revisions
**Signal:** session c7370b8f: poll-notion.md was edited twice (indices 73, 76) to replace `Agent Status` references with the actual Notion built-in `Status` property. The agent had to query the Notion API to discover the real property names before fixing the skill.
**Category:** incorrect-output
**Suggestion:** The "Required Notion database properties" table already lists the correct property names. Add a note: "Always verify property names match via `GET /v1/databases/{id}` before writing skills that reference Notion properties. The built-in `Status` field is not the same as a custom `Agent Status` select field." This prevents future authors from assuming a custom property exists.
