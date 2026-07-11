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
    if [ -z "$LAST_TS" ]; then
      echo "[self-improve] Could not parse last run timestamp. Treating as expired."
    else
      NOW_TS=$(date +%s)
      ELAPSED=$(( NOW_TS - LAST_TS ))
      if [ "$ELAPSED" -lt 86400 ]; then
        echo "[self-improve] Last run was $(( ELAPSED / 3600 ))h ago. Skipping (need 24h)."
        exit 0
      fi
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
MODIFIED_FILES="$MODIFIED_FILES $FILE_PATH"
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
CHANGELOG_ENTRY="## Self-Improvement Run — ${RUN_DATE}"$'\n\n'
# For each gap: append "- <file>: <category> (<short description>)\n"
CHANGELOG_ENTRY="${CHANGELOG_ENTRY}"$'\n---\n'

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

**Important:** Always `exit 0` from failure handling. This step must never propagate errors to the tick.
