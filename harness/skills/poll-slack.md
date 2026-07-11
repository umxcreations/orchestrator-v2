# poll-slack

Poll the configured Slack channel for messages since `last_sync_at` that mention `@agent`. If a message thread has no linked Notion ticket, create a stub ticket inline.

## Required env vars
- `SLACK_BOT_TOKEN`
- `SLACK_USER_TOKEN` (user token with `search:read` scope — required for search API)
- `SLACK_CHANNEL_ID`
- `NOTION_API_KEY`
- `NOTION_DATABASE_ID`

## Poll for messages mentioning @agent

Use `search.messages` to find all messages (top-level and replies) that mention the bot, across all threads:

```bash
LAST_SYNC_TS=$(sqlite3 harness/db/harness.db \
  "SELECT strftime('%s', last_sync_at) FROM sync_state WHERE id='global';")
curl -s "https://slack.com/api/search.messages?query=<@U0B5YJEQQ6P>&count=20&sort=timestamp&sort_dir=asc" \
  -H "Authorization: Bearer $SLACK_USER_TOKEN"
```

Filter results to `message.ts > last_sync_at`. For each matching message, extract:
- `channel.id` → `CHANNEL_ID`
- `ts` → `MESSAGE_TS`
- `thread_ts` (if present) → the root thread timestamp; use this as the thread identifier
- If no `thread_ts`, the message itself is the thread root: `THREAD_TS=$MESSAGE_TS`

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
      \"Task name\": {\"title\": [{\"text\": {\"content\": \"$STUB_TITLE\"}}]},
      \"Status\": {\"status\": {\"name\": \"Not started\"}},
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
