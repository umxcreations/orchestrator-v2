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
4. Available skills list: sync-state, poll-notion, poll-slack, poll-github, entity-registry, dispatch, e2e-test
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
- harness/skills/e2e-test.md

Reason about what action is needed. Then follow this workflow:

### For informational questions (no code changes needed)
Answer directly in Slack, update the Notion ticket, close the session.

### For feature requests or implementation work
**Do NOT write code immediately.** Follow this plan-first flow:

**Step A — Draft a plan and ask for feedback via Slack and Notion:**
1. Read the relevant source code to understand the current state.
2. Write a concise implementation plan: what you'll build, key design decisions, files to change, any open questions.
3. Define E2E test cases for this feature. For each user-visible behaviour the implementation will add or change, write a test case with:
   - `name`: short label (e.g. "New todo appears in list after submission")
   - `steps`: the Chrome DevTools MCP actions to perform (navigate, click, type, wait, assert)
   - `expected`: the observable outcome that confirms the feature works
   Hold these test cases in your working context — they will be used in Step B and included in the Slack plan message.
4. Post the plan to the Slack thread and ask for approval before proceeding:
   ```
   "Here's my plan for [feature]:
   - [key decision 1]
   - [key decision 2]
   ...
   - E2E test cases:
     - [test case 1 name]: [expected outcome]
     - [test case 2 name]: [expected outcome]
   Any questions or changes before I start? Reply @Cortex go to proceed."
   ```
5. Set Notion ticket `Status` → `Blocked` (waiting for approval).
6. Update session: `status='cancelled'` — the user's "@Cortex go" reply will spawn a new session to execute.

**Step B — Execute (only after user approves via "@Cortex go" reply):**
1. Create a new branch: `git -C harness/workspace checkout -b <short-kebab-description>`
2. Implement the plan.
3. Commit and push the implementation branch (do NOT open the PR yet):
   ```bash
   git add -A && git commit -m "feat: <description>"
   git push -u origin <branch-name>
   ```

4. Run E2E tests: read and follow `harness/skills/e2e-test.md`, passing:
   - The `TEST_CASES` defined in Step A
   - The current `SESSION_ID`
   - The Notion `PAGE_ID` for this ticket

   **If result is `passed`:**
   - Open the PR: `gh pr create --title "..." --body "..."`
   - Continue to the "When done" block below — set Status → `Done`.

   **If result is `failed` (5 attempts exhausted):**
   - Open the PR: `gh pr create --title "..." --body "E2E tests failed — needs review. Failing cases: <list>"`
   - Post to the Slack thread:
     ```
     E2E tests failed after 5 attempts for this PR.
     Failing cases:
     - <test case name>: <failure reason>
     Console errors: <final attempt errors>
     PR is open but needs human review: <PR_URL>
     ```
   - Set Notion `Status` → `Blocked` (instead of `Done`)
   - Set `GitHub PR` property to the PR URL
   - Then run the "When done" cleanup steps 1, 2, 4, and 5 only — skip step 3 (do NOT set Status → `Done`; it is already set to `Blocked` above).

When done:
1. Rename the Notion ticket from its stub title to a concise, meaningful name based on the work done (e.g. "Add archive feature for completed tasks").
2. Update the Notion ticket body with a summary of what was done: changes made, files modified, and the PR link if one was opened. Set `GitHub PR` property if a PR was created.
3. Set Notion ticket `Status` → `Done` as your LAST property update.
4. Update session record:
   sqlite3 harness/db/harness.db "UPDATE sessions SET status='completed', updated_at=datetime('now') WHERE id='<SESSION_ID>';"
5. Mark events as done:
   sqlite3 harness/db/harness.db "UPDATE events SET status='done', processed_at=datetime('now') WHERE context_key='<context_key>' AND status='processing';"

To rename + update the Notion ticket:
```bash
curl -s -X PATCH "https://api.notion.com/v1/pages/<PAGE_ID>" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d '{
    "properties": {
      "Task name": {"title": [{"text": {"content": "<meaningful title>"}}]},
      "Status": {"status": {"name": "Done"}},
      "Last Agent Update": {"date": {"start": "<today>"}},
      "GitHub PR": {"url": "<pr_url or null>"}
    }
  }'
```

To add a summary to the Notion page body:
```bash
curl -s -X PATCH "https://api.notion.com/v1/blocks/<PAGE_ID>/children" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d '{
    "children": [{
      "paragraph": {
        "rich_text": [{"text": {"content": "<summary of changes, files modified, PR link>"}}]
      }
    }]
  }'
```

If you cannot proceed without human input:
1. Post a Slack message to the originating thread explaining what you need.
2. Set Notion ticket `Status` → `Blocked`.
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

## Self-Improvement Notes (2026-06-04)

### Gap: Failure-path status overwrites Blocked
**Signal:** session 0576d92b: subagent review (index 299) found that the "When done" cleanup block would overwrite `Status → Blocked` with `Status → Done` on the E2E failure path. Agent had to re-read dispatch.md at index 299 to verify the logic, then commit a fix.
**Category:** ambiguity
**Suggestion:** Add an explicit guard in the "When done" block: "If the current session status is `failed`, do NOT set Notion `Status → Done`. Only set `Done` on a successful result." This prevents the cleanup block from silently erasing a Blocked or failed state.
