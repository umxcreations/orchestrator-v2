# E2E Testing in Dispatch — Design Spec

**Date:** 2026-06-03  
**Status:** Draft

## Overview

Subagents spawned by `dispatch.md` must run E2E tests against the workspace app before opening a PR. Tests are defined during the planning phase and executed after implementation, using Chrome DevTools MCP. A new `harness/skills/e2e-test.md` skill encapsulates all E2E logic.

## Changes to `dispatch.md`

### Step A (Planning) — addition

After writing the implementation plan and before posting to Slack for approval, the subagent defines test cases based on what it is about to build. Test cases are held in the subagent's working context for use in Step B.

Each test case has:
- A short name (e.g. "Todo item appears after creation")
- Steps to execute via Chrome DevTools MCP
- Expected outcome (what to assert)

These test cases are included in the plan posted to Slack so the user can review them before approving.

### Step B (Execute) — addition

After implementation (commit + push), before `gh pr create`:

1. Read and follow `harness/skills/e2e-test.md`, passing the test cases defined in Step A.
2. If result is `passed`: open PR normally, set Notion `Status` → `Done`.
3. If result is `failed` (exhausted retries): open PR, set Notion `Status` → `Blocked`, post failure summary + Slack message.

## New skill: `harness/skills/e2e-test.md`

### Phase 1: Start dev server

```bash
cd harness/workspace
npm run dev &
DEV_PID=$!
# Wait until localhost:3000 responds (poll up to 30s)
```

If the server fails to start, treat as attempt 1 failing and enter the fix loop.

### Phase 2: Run test cases

For each test case, using Chrome DevTools MCP:
1. Navigate to the relevant URL (default: `http://localhost:3000`)
2. Execute the test steps
3. Assert the expected outcome
4. Capture a screenshot (pass or fail)

Screenshots are saved locally as `harness/e2e-screenshots/<SESSION_ID>/<test-name>-attempt-<N>.png`.

### Phase 3: Fix loop (max 5 attempts)

If any test cases fail:
1. Analyse the failure (console errors, screenshot, assertion mismatch)
2. Fix the relevant code in `harness/workspace`
3. Restart the dev server if needed
4. Re-run all test cases
5. Increment attempt counter — if counter reaches 5, exit loop with `failed` status

### Phase 4: Teardown + report

```bash
kill $DEV_PID
```

Return one of:
- `passed` — all test cases green; include screenshots
- `failed` — include: which test cases failed, final attempt's error/console output, screenshots of failing state

### Phase 5: Upload screenshots to Notion

Regardless of pass/fail, upload each screenshot to Notion using the file upload API and attach as image blocks on the ticket:

```bash
# Step 1: Create a file upload
UPLOAD=$(curl -s -X POST "https://api.notion.com/v1/file_uploads" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d '{"content_type": "image/png"}')
UPLOAD_ID=$(echo "$UPLOAD" | jq -r '.id')

# Step 2: Send the file bytes
curl -s -X POST "https://api.notion.com/v1/file_uploads/$UPLOAD_ID/send" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  -F "file=@harness/e2e-screenshots/$SESSION_ID/$TEST_NAME-attempt-$N.png"

# Step 3: Attach as image block on the Notion page
curl -s -X PATCH "https://api.notion.com/v1/blocks/$PAGE_ID/children" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d "{\"children\": [{\"image\": {\"type\": \"file\", \"file\": {\"type\": \"uploaded_file\", \"uploaded_file\": {\"id\": \"$UPLOAD_ID\"}}}}]}"
```

Append a section to the Notion ticket body:
- A heading: "E2E Test Results — <passed|failed>"
- For each test case: test name, result emoji (✅/❌), and the screenshot as an uploaded image block

## Escalation on failure (5 attempts exhausted)

1. Open PR with `gh pr create` (code is preserved)
2. Post to Slack thread:
   - Which test cases failed
   - Final error/console output
   - Note that the PR is open but needs human review
3. Set Notion `Status` → `Blocked`
4. Set `GitHub PR` property to the PR URL
5. Append E2E results + screenshots to Notion body (as above)
6. Session closes as `completed`

## Constraints

- Dev server port: `3000` (Next.js default; no custom port configured)
- Chrome DevTools MCP tools must be loaded via `ToolSearch` before use (per MCP server instructions)
- Screenshots directory: `harness/e2e-screenshots/` (gitignored)
- Skill file is read-only to subagents (v1 constraint)
- The fix loop only modifies files in `harness/workspace/` — never harness skill files
