# E2E Testing in Dispatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `harness/skills/e2e-test.md` skill that subagents run after implementation to E2E-test the workspace app with Chrome DevTools MCP before opening a PR, and update `dispatch.md` to wire it into the Step A/B flow.

**Architecture:** A new standalone skill file encapsulates all E2E logic (start server, run tests, fix loop, teardown, upload screenshots to Notion). `dispatch.md`'s subagent prompt is updated in two places: Step A gains a "define test cases" section, and Step B gains a "run e2e-test.md" section between implementation and PR creation.

**Tech Stack:** Markdown skill files, Chrome DevTools MCP (`mcp__chrome-devtools__*`), Notion REST API (file upload + blocks), bash/curl/jq, Next.js dev server (`npm run dev`).

---

### Task 1: Add `harness/e2e-screenshots/` to `.gitignore`

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Add the screenshots directory to .gitignore**

Open `.gitignore` and append:
```
harness/e2e-screenshots/
```

- [ ] **Step 2: Verify gitignore is correct**

```bash
git check-ignore -v harness/e2e-screenshots/test.png
```
Expected output: `.gitignore:N:harness/e2e-screenshots/	harness/e2e-screenshots/test.png`

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: gitignore harness/e2e-screenshots"
```

---

### Task 2: Create `harness/skills/e2e-test.md`

**Files:**
- Create: `harness/skills/e2e-test.md`

- [ ] **Step 1: Create the skill file with the full content below**

```markdown
# e2e-test

Run E2E tests against the workspace app using Chrome DevTools MCP. Called by subagents after implementation, before opening a PR.

## Inputs (held in subagent working context)

- `TEST_CASES`: list of test cases defined during Step A planning, each with:
  - `name`: short label (e.g. "Todo item appears after creation")
  - `steps`: list of Chrome DevTools MCP actions to perform
  - `expected`: what to assert (element visible, text present, network response, etc.)
- `SESSION_ID`: the current session ID (used for screenshot filenames)
- `PAGE_ID`: the Notion page ID of the current ticket

## Phase 1: Start dev server

```bash
cd harness/workspace
npm run dev > /tmp/nextjs-dev.log 2>&1 &
DEV_PID=$!
echo $DEV_PID > /tmp/nextjs-dev.pid

# Poll until ready (up to 30s)
for i in $(seq 1 30); do
  curl -s http://localhost:3000 > /dev/null 2>&1 && break
  sleep 1
done
curl -s http://localhost:3000 > /dev/null 2>&1 || echo "WARN: server may not be ready"
```

If the dev server is not responding after 30s, treat this as a test failure and enter the fix loop (Phase 3) starting at attempt 1.

## Phase 2: Run test cases

Before running any Chrome DevTools MCP tools, load them:
```
ToolSearch: select:mcp__chrome-devtools__new_page,mcp__chrome-devtools__navigate_page,mcp__chrome-devtools__take_screenshot,mcp__chrome-devtools__wait_for,mcp__chrome-devtools__click,mcp__chrome-devtools__type_text,mcp__chrome-devtools__get_console_message,mcp__chrome-devtools__list_console_messages,mcp__chrome-devtools__close_page
```

For each test case in `TEST_CASES`:

Before running the first test case, create the screenshots directory:
```bash
mkdir -p harness/e2e-screenshots/$SESSION_ID
```

1. Open a new page: `mcp__chrome-devtools__new_page`
2. Navigate to `http://localhost:3000` (or the URL specified in the test case): `mcp__chrome-devtools__navigate_page`
3. Execute each step in the test case's `steps` list using the appropriate Chrome DevTools MCP tool
4. Assert the expected outcome. If assertion fails, record the failure reason.
5. Capture a screenshot regardless of pass/fail:
   ```
   mcp__chrome-devtools__take_screenshot → save to harness/e2e-screenshots/<SESSION_ID>/<test-name>-attempt-<N>.png
   ```
6. Close the page: `mcp__chrome-devtools__close_page`

Collect results: list of `{name, passed: bool, failure_reason, screenshot_path}`.

## Phase 3: Fix loop (max 5 attempts)

If all test cases passed → skip to Phase 4.

If any test cases failed and `attempt < 5`:
1. Read console errors from the last run (`mcp__chrome-devtools__list_console_messages`)
2. Analyse: failure reason + console errors + screenshot
3. Fix the relevant source files in `harness/workspace/src/` (never modify skill files)
4. If the fix changes server-side code, restart the dev server:
   ```bash
   kill $(cat /tmp/nextjs-dev.pid)
   cd harness/workspace && npm run dev > /tmp/nextjs-dev.log 2>&1 &
   echo $! > /tmp/nextjs-dev.pid
   # Poll until ready (same 30s loop as Phase 1)
   for i in $(seq 1 30); do
     curl -s http://localhost:3000 > /dev/null 2>&1 && break
     sleep 1
   done
   ```
5. Increment attempt counter, return to Phase 2.

If `attempt == 5` and tests still fail → proceed to Phase 4 with status `failed`.

## Phase 4: Teardown + report

```bash
kill $(cat /tmp/nextjs-dev.pid) 2>/dev/null
rm -f /tmp/nextjs-dev.pid /tmp/nextjs-dev.log
```

Return status to the caller:
- `passed` — all test cases green; `screenshots`: list of screenshot paths
- `failed` — `failed_cases`: list of `{name, failure_reason, screenshot_path}`; `console_errors`: final attempt's console output

## Phase 5: Upload screenshots to Notion

For each screenshot captured during all attempts, upload to Notion and attach as an image block.

### 5a: Upload the file

```bash
# Create upload
UPLOAD=$(curl -s -X POST "https://api.notion.com/v1/file_uploads" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d '{"content_type": "image/png"}')
UPLOAD_ID=$(echo "$UPLOAD" | jq -r '.id')

# Send file bytes
curl -s -X POST "https://api.notion.com/v1/file_uploads/$UPLOAD_ID/send" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  -F "file=@<screenshot_path>"
```

### 5b: Append heading + image blocks to Notion ticket

```bash
# Build the children array: one heading block + one image block per test case
curl -s -X PATCH "https://api.notion.com/v1/blocks/$PAGE_ID/children" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d '{
    "children": [
      {
        "heading_2": {
          "rich_text": [{"text": {"content": "E2E Test Results — <passed|failed>"}}]
        }
      },
      {
        "paragraph": {
          "rich_text": [{"text": {"content": "<test-name>: ✅ or ❌ <failure_reason if failed>"}}]
        }
      },
      {
        "image": {
          "type": "file",
          "file": {
            "type": "uploaded_file",
            "uploaded_file": {"id": "<UPLOAD_ID>"}
          }
        }
      }
    ]
  }'
```

Repeat the paragraph + image pair for each test case.
```

- [ ] **Step 2: Verify the file was created**

```bash
ls -la harness/skills/e2e-test.md
```
Expected: file exists with non-zero size.

- [ ] **Step 3: Commit**

```bash
git add harness/skills/e2e-test.md
git commit -m "feat: add e2e-test skill with Chrome DevTools MCP and Notion screenshot upload"
```

---

### Task 3: Update `dispatch.md` — Step A: define test cases during planning

**Files:**
- Modify: `harness/skills/dispatch.md`

- [ ] **Step 1: Locate Step A in dispatch.md**

In `harness/skills/dispatch.md`, find the Step A block inside the subagent prompt (around line 110–122). It currently ends with setting Notion status to `Blocked` and cancelling the session.

- [ ] **Step 2: Add test case definition after the plan is written, before the Slack post**

Insert the following block between "Write a concise implementation plan" (step 2 of Step A) and "Post the plan to the Slack thread" (step 3 of Step A):

```
3. Define E2E test cases for this feature. For each user-visible behaviour the implementation will add or change, write a test case with:
   - `name`: short label (e.g. "New todo appears in list after submission")
   - `steps`: the Chrome DevTools MCP actions to perform (navigate, click, type, wait, assert)
   - `expected`: the observable outcome that confirms the feature works
   Hold these test cases in your working context — they will be used in Step B and included in the Slack plan message.
```

Renumber the subsequent steps in Step A (old step 3 → 4, old step 4 → 5, old step 5 → 6).

- [ ] **Step 3: Add test cases to the Slack plan message template**

In the Slack message template (the block starting with `"Here's my plan for [feature]:`), append after the last bullet:
```
   - E2E test cases:
     - [test case 1 name]: [expected outcome]
     - [test case 2 name]: [expected outcome]
```

- [ ] **Step 4: Verify the edit looks correct**

```bash
grep -n "E2E test cases\|Define E2E\|test case" harness/skills/dispatch.md
```
Expected: 3+ matches showing the new lines.

- [ ] **Step 5: Commit**

```bash
git add harness/skills/dispatch.md
git commit -m "feat: dispatch Step A now defines E2E test cases during planning"
```

---

### Task 4: Update `dispatch.md` — Step B: run e2e-test.md before PR

**Files:**
- Modify: `harness/skills/dispatch.md`

- [ ] **Step 1: Locate Step B in dispatch.md**

Find the Step B block in the subagent prompt. It currently has:
1. Create a new branch
2. Implement the plan
3. Commit, push, and open a PR

- [ ] **Step 2: Insert E2E test step between "commit + push" and "gh pr create"**

Replace step 3 with the following two steps (renumbering accordingly):

```
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
   - Then run the "When done" cleanup (update session, mark events done) — session closes as `completed`.
```

- [ ] **Step 3: Verify the edit looks correct**

```bash
grep -n "e2e-test\|E2E\|passed\|failed.*attempt" harness/skills/dispatch.md
```
Expected: multiple matches showing the new Step B content.

- [ ] **Step 4: Commit**

```bash
git add harness/skills/dispatch.md
git commit -m "feat: dispatch Step B runs e2e-test.md before opening PR"
```

---

### Task 5: Add `e2e-test` to the available skills list in the subagent prompt

**Files:**
- Modify: `harness/skills/dispatch.md`

- [ ] **Step 1: Find the available skills list in the subagent prompt**

In `dispatch.md`, locate the "Available skills" list (around line 94–101):
```
Available skills (read and follow them as needed):
- harness/skills/sync-state.md
- harness/skills/poll-notion.md
...
```

- [ ] **Step 2: Add e2e-test.md to the list**

Append to the list:
```
- harness/skills/e2e-test.md
```

- [ ] **Step 3: Also update Step 3 of dispatch.md (context resolution step)**

In Step 3 of the top-level dispatch skill (not the subagent prompt), item 4 lists available skills. Update it:
```
4. Available skills list: sync-state, poll-notion, poll-slack, poll-github, entity-registry, dispatch, e2e-test
```

- [ ] **Step 4: Verify**

```bash
grep -n "e2e-test" harness/skills/dispatch.md
```
Expected: 2 matches (one in available skills list, one in Step 3).

- [ ] **Step 5: Commit**

```bash
git add harness/skills/dispatch.md
git commit -m "chore: add e2e-test to subagent available skills list"
```

---

### Task 6: Manual smoke-test of the skill files

**Files:** (read-only verification)

- [ ] **Step 1: Confirm e2e-test.md is well-formed**

```bash
wc -l harness/skills/e2e-test.md
```
Expected: > 80 lines.

- [ ] **Step 2: Confirm dispatch.md still parses Step A → Step B in order**

```bash
grep -n "Step A\|Step B\|E2E\|e2e-test\|Define E2E\|test case" harness/skills/dispatch.md
```
Expected: Step A section mentions "Define E2E test cases", Step B section mentions "e2e-test.md" and the pass/fail branching.

- [ ] **Step 3: Confirm .gitignore has the screenshots dir**

```bash
grep "e2e-screenshots" .gitignore
```
Expected: `harness/e2e-screenshots/`

- [ ] **Step 4: Final commit if any last tweaks were needed, otherwise confirm all clean**

```bash
git status
```
Expected: `nothing to commit, working tree clean`
