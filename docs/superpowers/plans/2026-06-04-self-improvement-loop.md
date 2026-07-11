# Self-Improvement Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a daily self-improvement step (step 5) to the tick sequence that analyzes Claude Code transcripts, identifies skill gaps, appends improvement suggestions to harness skill/doc files, and commits the changes.

**Architecture:** A new `harness/skills/self-improve.md` skill runs inline after the tick lock is released. It gates on two conditions: harness idle (no pending/processing events, no running sessions) and 24h elapsed since last successful run. It reads `.jsonl` transcript files, reasons about four gap categories, appends `## Self-Improvement Notes` blocks to affected files, updates `CHANGELOG.md`, commits, and writes to a flat state file. A circuit breaker disables the skill after 3 consecutive failures and posts a Slack alert.

**Tech Stack:** SQLite (existing `harness/db/harness.db`), bash, `find`/`grep` for transcript scanning, Claude reasoning for gap analysis, git for committing.

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `harness/skills/self-improve.md` | The full self-improvement skill |
| Modify | `harness/CLAUDE.md` | Add step 5 to tick sequence |
| Modify | `harness/.env.example` | Already done in spec session — verify present |
| Create (runtime) | `harness/db/self-improvement-last-run.txt` | State file written by skill at runtime |
| Create (runtime) | `CHANGELOG.md` | Created by skill on first run |

---

## Task 1: Create the self-improve skill — gate logic

**Files:**
- Create: `harness/skills/self-improve.md` (gate sections only)

- [ ] **Step 1: Create the skill file with frontmatter and gate checks**

Create `harness/skills/self-improve.md` with this exact content:

```markdown
---
type: reference
last_verified: 2026-06-04
owner: self-improvement
---

# self-improve

Analyze Claude Code transcripts from the last 24 hours, identify skill gaps, and append improvement suggestions to harness skill/doc files. Runs as step 5 of the tick — after lock release. Skips silently if gate conditions are not met.

## DB path
Always use: `harness/db/harness.db`

## State file path
Always use: `harness/db/self-improvement-last-run.txt`

---

## Step 1: Check gate conditions

Both conditions must pass. If either fails, exit silently — do not log, do not error.

### 1a: Circuit breaker check

```bash
STATE_FILE="harness/db/self-improvement-last-run.txt"
if [ -f "$STATE_FILE" ] && head -1 "$STATE_FILE" | grep -q "^DISABLED"; then
  echo "[self-improve] Disabled by circuit breaker. Remove DISABLED line from $STATE_FILE to re-enable."
  exit 0
fi
```

### 1b: Idle check — no pending/processing events, no running sessions

```bash
PENDING_EVENTS=$(sqlite3 harness/db/harness.db \
  "SELECT COUNT(*) FROM events WHERE status IN ('pending', 'processing');")
RUNNING_SESSIONS=$(sqlite3 harness/db/harness.db \
  "SELECT COUNT(*) FROM sessions WHERE status='running';")

if [ "$PENDING_EVENTS" -gt 0 ] || [ "$RUNNING_SESSIONS" -gt 0 ]; then
  echo "[self-improve] Harness not idle (events=$PENDING_EVENTS, sessions=$RUNNING_SESSIONS). Skipping."
  exit 0
fi
```

### 1c: 24h gate

```bash
STATE_FILE="harness/db/self-improvement-last-run.txt"

if [ -f "$STATE_FILE" ]; then
  # Extract timestamp from last successful run (first ok line)
  LAST_OK=$(grep "status: ok" "$STATE_FILE" | head -1 | cut -d'|' -f1 | xargs)
  if [ -n "$LAST_OK" ]; then
    LAST_TS=$(date -d "$LAST_OK" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_OK" +%s 2>/dev/null)
    NOW_TS=$(date +%s)
    ELAPSED=$(( NOW_TS - LAST_TS ))
    if [ "$ELAPSED" -lt 86400 ]; then
      echo "[self-improve] Last run was $(( ELAPSED / 3600 ))h ago. Skipping (need 24h)."
      exit 0
    fi
  fi
fi

echo "[self-improve] Gate passed. Starting improvement run."
```

---

## Step 2: Scan for transcripts

```bash
TRANSCRIPTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
STATE_FILE="harness/db/self-improvement-last-run.txt"

if [ -f "$STATE_FILE" ] && grep -q "status: ok" "$STATE_FILE"; then
  TRANSCRIPT_FILES=$(find "$TRANSCRIPTS_DIR" -name "*.jsonl" -newer "$STATE_FILE" 2>/dev/null)
else
  # First run — scan last 24h
  TRANSCRIPT_FILES=$(find "$TRANSCRIPTS_DIR" -name "*.jsonl" -mtime -1 2>/dev/null)
fi

if [ -z "$TRANSCRIPT_FILES" ]; then
  echo "[self-improve] No new transcripts found. Nothing to analyze."
  # Still write an ok entry with 0 changes so the 24h gate advances
  ENTRY="$(date -u +%Y-%m-%dT%H:%M:%SZ) | status: ok | changes: 0 | files: none"
  if [ -f "$STATE_FILE" ]; then
    EXISTING=$(cat "$STATE_FILE")
    printf "%s\n%s" "$ENTRY" "$EXISTING" > "$STATE_FILE"
  else
    echo "$ENTRY" > "$STATE_FILE"
  fi
  exit 0
fi

echo "[self-improve] Found transcripts to analyze:"
echo "$TRANSCRIPT_FILES"
```

---

## Step 3: Analyze transcripts for skill gaps

Read each transcript file listed in `$TRANSCRIPT_FILES`. For each file, extract all tool calls by parsing the `.jsonl` lines (each line is a JSON object). You are looking for four gap signal categories:

### Category 1: Ambiguity (re-reads)
Look for `Read` tool calls where `input.file_path` points to a file inside `harness/skills/` or `.claude/skills/` that appears **more than once** in the same session (same `sessionId` field). Each re-read signals the skill wasn't clear on first read.

### Category 2: Incorrect output (revisions)
Look for sequences where a `Write` or `Edit` tool call is followed later in the same session by another `Write` or `Edit` to the **same file_path**, suggesting the first output was wrong. Also look across sessions sharing the same `context_key` (extractable from session records) where the same file is rewritten.

### Category 3: Missing recovery guidance (loops)
Look for `Bash` tool calls where the output (in the `tool_result` message following the tool call) contains an error string that appears **3 or more times** before a different output appears. The escape path — the tool call or reasoning that finally broke the loop — is the recovery guidance to add.

### Category 4: Rule violations
Read the current skill files and CLAUDE.md to understand what rules exist. Then look for tool calls that violate those rules. Examples:
- A `Write` tool call to a path inside `harness/skills/` from a non-improvement session (v1 constraint violation)
- A `Bash` tool call opening a PR before E2E tests ran (plan-first violation)
- A session that updated Notion `Status → Done` without posting to Slack first

For each gap found, record:
```
FILE: <which skill/doc file owns this gap>
CATEGORY: ambiguity | incorrect-output | missing-recovery | rule-violation
SIGNAL: <exact observation — session ID, tool call sequence, error text>
SUGGESTION: <specific, actionable improvement to the skill text>
```

If a gap spans multiple files, assign it to the **authoritative source** — the file that defines the rule or procedure, not files that merely reference it.

Build a `GAPS` list from all findings. If `GAPS` is empty after analyzing all transcripts, write an ok entry to the state file and exit cleanly (same as "no transcripts found").

---

## Step 4: Append suggestions to files

For each unique file in `GAPS`, append a suggestions block. Track all modified files in `MODIFIED_FILES`.

```bash
MODIFIED_FILES=""
RUN_DATE=$(date -u +%Y-%m-%d)

# For each unique FILE in GAPS:
#   0. Scope guard — skip files outside the allowed list:
ALLOWED=0
for PREFIX in "harness/skills/" "CLAUDE.md" "harness/CLAUDE.md" \
              "CONTEXT.md" ".claude/skills/"; do
  case "$FILE_PATH" in
    "$PREFIX"*) ALLOWED=1 ;;
  esac
done
if [ "$ALLOWED" -eq 0 ]; then
  echo "[self-improve] WARN: $FILE_PATH not in allowed scope — skipping"
  continue
fi

#   1. Append to that file (unquoted heredoc so $RUN_DATE expands):
cat >> "$FILE_PATH" <<NOTES_EOF

## Self-Improvement Notes ($RUN_DATE)

### Gap: <short title>
**Signal:** <exact observation from transcript>
**Category:** ambiguity | incorrect-output | missing-recovery | rule-violation
**Suggestion:** <specific, actionable improvement to the skill text>
NOTES_EOF

#   2. Add to MODIFIED_FILES:
MODIFIED_FILES="$MODIFIED_FILES <FILE_PATH>"
```

If the gap analysis identified a pattern recurring across 3+ sessions with no existing skill to contain it, create a new skill file using this template:

```markdown
---
type: reference
last_verified: YYYY-MM-DD
owner: self-improvement
---

# <skill-name>

One-line purpose statement derived from the recurring pattern.

## Step 1: ...
## Step 2: ...
```

Save to `harness/skills/<skill-name>.md`. Add it to `MODIFIED_FILES`. Do NOT add it to `dispatch.md`'s available skills list — that is a human decision.

---

## Step 5: Write CHANGELOG.md entry

Append (or create) `CHANGELOG.md` at the repo root with a new entry at the top:

```bash
CHANGELOG_ENTRY="## Self-Improvement Run — $RUN_DATE\n\n"
# For each gap: append "- <file>: <category> (<short description>)\n"
CHANGELOG_ENTRY="$CHANGELOG_ENTRY\n---\n"

if [ -f "CHANGELOG.md" ]; then
  EXISTING_CHANGELOG=$(cat CHANGELOG.md)
  printf "%s\n%s" "$CHANGELOG_ENTRY" "$EXISTING_CHANGELOG" > CHANGELOG.md
else
  printf "# Changelog\n\n%s" "$CHANGELOG_ENTRY" > CHANGELOG.md
fi
```

---

## Step 6: Commit

```bash
FILE_COUNT=$(echo "$MODIFIED_FILES" | wc -w | xargs)
CHANGE_COUNT=$FILE_COUNT  # one entry per modified file

# Build commit body — one line per gap
COMMIT_BODY=""
# For each gap: COMMIT_BODY="$COMMIT_BODY\n- <file>: <category> (<short description>)"

git add CHANGELOG.md $MODIFIED_FILES
git commit -m "$(cat <<EOF
chore: self-improvement run $RUN_DATE — $CHANGE_COUNT gaps in $FILE_COUNT files
$COMMIT_BODY
EOF
)"
```

---

## Step 7: Update state file

On success:

```bash
CHANGED_FILES_LIST=$(echo $MODIFIED_FILES | tr ' ' ',')
ENTRY="$(date -u +%Y-%m-%dT%H:%M:%SZ) | status: ok | changes: $CHANGE_COUNT | files: $CHANGED_FILES_LIST"

if [ -f "$STATE_FILE" ]; then
  EXISTING=$(cat "$STATE_FILE")
  printf "%s\n%s" "$ENTRY" "$EXISTING" > "$STATE_FILE"
else
  echo "$ENTRY" > "$STATE_FILE"
fi
```

---

## Step 8: Failure handling

If **any step above fails**, execute this block instead of the normal completion:

```bash
ERROR_REASON="<description of what failed>"
ENTRY="$(date -u +%Y-%m-%dT%H:%M:%SZ) | status: failed | error: $ERROR_REASON"

if [ -f "$STATE_FILE" ]; then
  EXISTING=$(cat "$STATE_FILE")
  printf "%s\n%s" "$ENTRY" "$EXISTING" > "$STATE_FILE"
else
  echo "$ENTRY" > "$STATE_FILE"
fi

# Count consecutive failures at top of file
CONSECUTIVE=$(awk '/^[0-9].*status: failed/{c++} /^[0-9].*status: ok/{exit} END{print c}' "$STATE_FILE")

if [ "$CONSECUTIVE" -ge 3 ]; then
  DISABLE_LINE="DISABLED: too many consecutive failures ($CONSECUTIVE) — last error: $ERROR_REASON"
  EXISTING=$(cat "$STATE_FILE")
  printf "%s\n%s" "$DISABLE_LINE" "$EXISTING" > "$STATE_FILE"

  # Post Slack alert if configured
  if [ -n "$SLACK_ALERT_CHANNEL" ] && [ -n "$SLACK_BOT_TOKEN" ]; then
    curl -s -X POST "https://slack.com/api/chat.postMessage" \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"channel\": \"$SLACK_ALERT_CHANNEL\", \"text\": \":warning: Self-improvement loop disabled after $CONSECUTIVE consecutive failures. Last error: $ERROR_REASON. Remove DISABLED line from harness/db/self-improvement-last-run.txt to re-enable.\"}"
  else
    echo "[self-improve] CIRCUIT BREAKER TRIGGERED: $DISABLE_LINE" >&2
  fi
fi

exit 0
```

**Important:** Always `exit 0` from failure handling. Step 5 must never propagate errors to the tick.
```

- [ ] **Step 2: Verify the file was created**

```bash
ls -la harness/skills/self-improve.md
head -5 harness/skills/self-improve.md
```

Expected: file exists, starts with `---` frontmatter.

- [ ] **Step 3: Commit**

```bash
git add harness/skills/self-improve.md
git commit -m "feat: add self-improve skill — gate logic and full implementation"
```

---

## Task 2: Wire step 5 into the tick sequence

**Files:**
- Modify: `harness/CLAUDE.md`

- [ ] **Step 1: Read the current tick sequence**

```bash
cat harness/CLAUDE.md
```

- [ ] **Step 2: Add step 5 to the tick sequence**

The current `harness/CLAUDE.md` ends at step 4. Add step 5 immediately after step 4. The section to modify looks like:

```markdown
4. **sync-state**: Update `last_sync_at` → release tick lock
```

Change it to:

```markdown
4. **sync-state**: Update `last_sync_at` → release tick lock

5. **self-improve** (runs only if harness is idle + 24h gate passes):
   - Skill: `harness/skills/self-improve.md`
   - Skips silently if: any pending/processing events, any running sessions, < 24h since last run, or circuit breaker active.
   - Failure in this step does NOT affect the tick. `ScheduleWakeup` has already been called in step 4.
```

- [ ] **Step 3: Verify the change looks right**

```bash
cat harness/CLAUDE.md
```

Expected: tick sequence now has 5 steps, step 5 references `harness/skills/self-improve.md`.

- [ ] **Step 4: Commit**

```bash
git add harness/CLAUDE.md
git commit -m "feat: wire self-improve as step 5 in tick sequence"
```

---

## Task 3: Verify .env.example has the new vars

**Files:**
- Verify: `harness/.env.example`

- [ ] **Step 1: Check the env example**

```bash
cat harness/.env.example
```

Expected output includes these two lines (added during spec/grill session):
```
SLACK_ALERT_CHANNEL=         # channel ID for circuit breaker alerts (optional)
CLAUDE_PROJECTS_DIR=         # override ~/.claude/projects/ if non-standard (optional)
```

- [ ] **Step 2: If missing, add them**

If either line is absent, append to `harness/.env.example`:

```bash
cat >> harness/.env.example << 'EOF'

# Self-improvement loop
SLACK_ALERT_CHANNEL=         # channel ID for circuit breaker alerts (optional)
CLAUDE_PROJECTS_DIR=         # override ~/.claude/projects/ if non-standard (optional)
EOF
```

- [ ] **Step 3: Commit only if a change was made**

```bash
git diff harness/.env.example
# Only commit if there's a diff:
git add harness/.env.example
git commit -m "chore: add self-improvement env vars to .env.example"
```

---

## Task 4: Smoke test the gate logic

**Files:**
- Read: `harness/db/harness.db`
- Read: `harness/db/self-improvement-last-run.txt` (may not exist yet)

The self-improve skill is a markdown skill read and executed by Claude — there are no unit tests in the traditional sense. Instead, verify each gate condition manually by querying the DB and checking state.

- [ ] **Step 1: Verify idle check queries work**

```bash
sqlite3 harness/db/harness.db \
  "SELECT COUNT(*) FROM events WHERE status IN ('pending', 'processing');"
sqlite3 harness/db/harness.db \
  "SELECT COUNT(*) FROM sessions WHERE status='running';"
```

Expected: both return integers (0 or more). If either query errors, the DB schema is missing the expected columns — investigate `harness/db/schema.sql`.

- [ ] **Step 2: Verify transcript scan finds files**

```bash
TRANSCRIPTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
find "$TRANSCRIPTS_DIR" -name "*.jsonl" -mtime -1 | head -10
```

Expected: one or more `.jsonl` files listed. If zero, the transcripts directory is empty or doesn't exist — check `$TRANSCRIPTS_DIR` exists.

- [ ] **Step 3: Simulate a state file and verify 24h gate**

```bash
STATE_FILE="harness/db/self-improvement-last-run.txt"

# Write a fake "ran 1 hour ago" entry
echo "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ) | status: ok | changes: 1 | files: harness/skills/dispatch.md" > "$STATE_FILE"

# Check that the gate would skip
LAST_OK=$(grep "status: ok" "$STATE_FILE" | head -1 | cut -d'|' -f1 | xargs)
LAST_TS=$(date -d "$LAST_OK" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_OK" +%s 2>/dev/null)
NOW_TS=$(date +%s)
ELAPSED=$(( NOW_TS - LAST_TS ))
echo "Elapsed seconds: $ELAPSED (need >= 86400 to run)"
```

Expected: `Elapsed seconds: ~3600` — confirms the gate would skip.

- [ ] **Step 4: Remove the test state file**

```bash
rm harness/db/self-improvement-last-run.txt
```

- [ ] **Step 5: Simulate circuit breaker detection**

```bash
STATE_FILE="harness/db/self-improvement-last-run.txt"
cat > "$STATE_FILE" << 'EOF'
2026-06-04T12:00:00Z | status: failed | error: git commit failed
2026-06-04T06:00:00Z | status: failed | error: git commit failed
2026-06-04T00:00:00Z | status: failed | error: git commit failed
EOF

CONSECUTIVE=$(awk '/^[0-9].*status: failed/{c++} /^[0-9].*status: ok/{exit} END{print c}' "$STATE_FILE")
echo "Consecutive failures: $CONSECUTIVE"
```

Expected: `Consecutive failures: 3`

- [ ] **Step 6: Clean up**

```bash
rm harness/db/self-improvement-last-run.txt
```

- [ ] **Step 7: Verify first-run gate passes (no state file)**

```bash
# Ensure no state file exists
rm -f harness/db/self-improvement-last-run.txt

STATE_FILE="harness/db/self-improvement-last-run.txt"
if [ ! -f "$STATE_FILE" ]; then
  echo "[self-improve] Gate passed. Starting improvement run."
fi
```

Expected: outputs `[self-improve] Gate passed. Starting improvement run.`

---

## Task 5: End-to-end dry run

Run the self-improve skill in a real tick context by reading and following it manually, with the harness in an idle state.

- [ ] **Step 1: Confirm harness is idle**

```bash
sqlite3 harness/db/harness.db \
  "SELECT COUNT(*) FROM events WHERE status IN ('pending','processing');"
sqlite3 harness/db/harness.db \
  "SELECT COUNT(*) FROM sessions WHERE status='running';"
```

Both must return `0`. If not, wait for active work to complete before proceeding.

- [ ] **Step 2: Read and follow harness/skills/self-improve.md**

Read the skill and execute it step by step. The gate will pass (no state file, harness idle), transcripts will be scanned, gaps analyzed, and suggestions appended.

- [ ] **Step 3: Verify output**

After the skill completes:

```bash
# State file should exist with an ok entry
cat harness/db/self-improvement-last-run.txt

# CHANGELOG.md should exist with a run entry
cat CHANGELOG.md

# Git log should show a self-improvement commit (or "no changes" if 0 gaps found)
git log --oneline -3
```

Expected:
- State file: first line is `YYYY-MM-DDTHH:MM:SSZ | status: ok | changes: N | files: ...`
- CHANGELOG.md: exists with a `## Self-Improvement Run — YYYY-MM-DD` section
- Git log: either a `chore: self-improvement run` commit, or state file shows `changes: 0`

- [ ] **Step 4: If gaps were found, verify suggestion format**

```bash
# Check that any modified skill file has the notes block appended correctly
grep -l "Self-Improvement Notes" harness/skills/*.md CLAUDE.md CONTEXT.md 2>/dev/null
```

Open one of the matched files and confirm the `## Self-Improvement Notes (YYYY-MM-DD)` block is well-formed at the bottom.

---

## Implementation Tasks

Synthesized from this review's findings. Each task derives from a specific finding above.

- [ ] **T1 (P1, human: ~30min / CC: ~5min)** — self-improve skill — Fix three issues found in review
  - Surfaced by: Architecture D3 (GAPS bash var → use MODIFIED_FILES), Code Quality D4 (heredoc quoting → unquoted), Failure Modes D7 (scope guard → allowlist check)
  - Files: `harness/skills/self-improve.md` (fixes already incorporated in plan Task 1 Step 1)
  - Verify: grep for `NOTES_EOF` (unquoted), `ALLOWED=0` (scope guard), `FILE_COUNT=` (no $GAPS reference)

- [ ] **T2 (P1, human: ~5min / CC: ~2min)** — harness/CLAUDE.md — Wire step 5
  - Surfaced by: Architecture (integration point)
  - Files: `harness/CLAUDE.md`
  - Verify: `cat harness/CLAUDE.md` shows 5-step tick sequence referencing `self-improve.md`

- [ ] **T3 (P2, human: ~15min / CC: ~3min)** — smoke tests — First-run gate test
  - Surfaced by: Test Review D5 (first-run path only covered implicitly by Task 5)
  - Files: plan doc (test is manual execution in Task 4 Step 7)
  - Verify: gate outputs `[self-improve] Gate passed.` when no state file exists

---

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | — | — |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAN | 4 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **UNRESOLVED:** 0
- **VERDICT:** ENG CLEARED — all findings resolved, 0 critical gaps. Ready to implement.
