# Self-Improvement Loop — Design Spec

**Date:** 2026-06-04  
**Status:** Approved  
**Inspired by:** [SkillOpt (Microsoft)](https://github.com/microsoft/SkillOpt) — treat skill docs as trainable components, improve them from execution trajectories without touching model weights.

---

## Overview

A daily self-improvement step woven into the main `/loop` tick. After dispatch completes and the harness is idle, the loop analyzes Claude Code transcripts from the last 24 hours, identifies skill gaps, and appends improvement suggestions directly to the relevant skill/doc files, then commits. No human approval required — the log file is the audit trail.

---

## Architecture

Step 5 added to the tick sequence in `harness/CLAUDE.md`:

```
1. sync-state (acquire lock)
2. poll-notion / poll-slack / poll-github
3. dispatch
4. sync-state (release lock)
5. self-improve  ← NEW (skips silently if gate fails)
```

The step runs **after** the tick lock is released. A failure in step 5 never affects the normal tick cycle.

New file: `harness/skills/self-improve.md`

---

## Gate Conditions

Both must pass for the skill to run:

**Idle check** — no pending or in-flight events, no running sessions:
```bash
sqlite3 harness/db/harness.db "SELECT id FROM events WHERE status IN ('pending', 'processing');"
sqlite3 harness/db/harness.db "SELECT id FROM sessions WHERE status='running';"
```
If either returns rows → skip silently.

**24h gate** — read `harness/db/self-improvement-last-run.txt`:
- If file doesn't exist → gate passes (first run)
- If last successful run < 24h ago → skip silently
- If file starts with `DISABLED` → skip silently (circuit breaker active)

---

## State File

Path: `harness/db/self-improvement-last-run.txt`

Format — newest entry prepended at top:
```
2026-06-04T14:32:00Z | status: ok | changes: 3 | files: harness/skills/dispatch.md, CONTEXT.md
2026-06-03T09:15:00Z | status: ok | changes: 1 | files: harness/skills/sync-state.md
```

On failure, prepend a failure entry:
```
2026-06-05T08:00:00Z | status: failed | error: <reason>
```

---

## Circuit Breaker

If 3 consecutive `status: failed` entries appear at the top of the state file with no `status: ok` between them:

1. Prepend `DISABLED: too many consecutive failures (3) — last error: <reason>` to the state file
2. Post a Slack alert to `SLACK_ALERT_CHANNEL` from `.env` (fall back to stderr log if env var unset or Slack unavailable)
3. The skill skips on all subsequent ticks until the `DISABLED` line is manually removed

---

## Transcript Scan

Transcript base path: `${CLAUDE_PROJECTS_DIR:-~/.claude/projects/}` — configurable via `.env`, defaults to `~/.claude/projects/` which is standard on all machines.

```bash
TRANSCRIPTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

# If state file exists and has a successful run:
find "$TRANSCRIPTS_DIR" -name "*.jsonl" -newer harness/db/self-improvement-last-run.txt

# First run (no state file):
find "$TRANSCRIPTS_DIR" -name "*.jsonl" -mtime -1
```

All matching transcript files are read and analyzed by Claude directly — no external LLM call.

---

## Gap Analysis — Four Signal Categories

### 1. Ambiguity (re-reads)
Skill file read more than once within a single session. Indicates the instructions weren't clear enough on first read.

### 2. Incorrect output (revisions)
Output produced then corrected later in the same session, or re-done in a follow-up session on the same `context_key`. Indicates the skill's expected output wasn't specified precisely enough.

### 3. Missing recovery guidance (loops)
Same error appearing 3+ times before resolution. Capture both the stuck pattern AND how the agent eventually escaped — the escape path is the recovery guidance to add.

### 4. Rule violations
Agent took an action explicitly prohibited by a skill or CLAUDE.md (e.g., attempted to create a skill file, skipped plan-first flow, omitted Slack notification). Indicates the rule needs to be more prominent or specific.

---

## Output Format

For each file with identified gaps, append:

```markdown
## Self-Improvement Notes (YYYY-MM-DD)

### Gap: <short title>
**Signal:** <what was observed in the transcript>
**Category:** ambiguity | incorrect-output | missing-recovery | rule-violation
**Suggestion:** <specific, actionable improvement to the skill text>
```

Multiple gaps in the same file get multiple `###` sections under the same `##` block.

When a gap spans multiple files (e.g., a rule defined in `dispatch.md` but referenced in `CLAUDE.md`), write the suggestion only to the **authoritative source** — the file that owns the rule. The improvement run must reason about ownership rather than duplicating suggestions across all referencing files.

---

## New Skill File Creation

If analysis identifies a recurring pattern across 3+ sessions that doesn't fit any existing skill, the loop **may create** a new skill file in `harness/skills/`. The new file must use the standard skill template:

```markdown
---
type: reference
last_verified: YYYY-MM-DD
owner: self-improvement
---

# skill-name

One-line purpose statement.

## Step 1: ...
## Step 2: ...
```

The new file must also:
- Be listed in the commit message so it's visible in the log
- Not be auto-added to `dispatch.md`'s available skills list (human decision)

---

## Scope of Files

The loop operates only on:
- `harness/skills/*.md` — all harness skill files
- `harness/CLAUDE.md` — tick sequence
- `CLAUDE.md` — project instructions
- `CONTEXT.md` — domain glossary
- `.claude/skills/**/*.md` — project-local superpowers skills

Never touches:
- `harness/workspace/` — the target repo
- `harness/db/harness.db` — DB schema or data
- Notion, Slack, or GitHub (except circuit breaker Slack alert)

---

## Failure Handling

If any step in the skill fails:
1. Prepend a `status: failed` entry to the state file with the error reason
2. Exit cleanly — do not affect `last_sync_at` or the tick lock
3. Check circuit breaker threshold (3 consecutive failures → disable)

A failed run does not update the 24h gate timestamp, so it retries on the next idle tick.

---

## Commit

The skill tracks the list of files it appends to during the run. After all suggestion blocks are written:

**1. Append to `CHANGELOG.md`** (create if it doesn't exist) with an entry per run:

```markdown
## Self-Improvement Run — YYYY-MM-DD

- dispatch.md: ambiguity (curl header order in Step 3)
- dispatch.md: missing-recovery (Notion 404 handling)
- sync-state.md: rule-violation (tick lock not released on poller failure)
```

**2. Stage and commit only modified files explicitly:**

```bash
# MODIFIED_FILES is built up during the run as each file is appended to
# Always include CHANGELOG.md
git add CHANGELOG.md $MODIFIED_FILES
git commit -m "$(cat <<EOF
chore: self-improvement run YYYY-MM-DD — N gaps found in X files

- file.md: category (short description)
- file.md: category (short description)
EOF
)"
```

Never use `git add -A` — this prevents accidentally staging unrelated workspace changes or in-progress work.

---

## Future Evolution

- **v2:** Graduate from append-only to in-place rewrites (Option A from design session)
- **v3:** Expand gap analysis to also capture positive patterns and user feedback from Slack threads (Option C signal set)
- **v4:** Add validation gating — only apply suggestions that survive a held-out validation split (full SkillOpt model)
