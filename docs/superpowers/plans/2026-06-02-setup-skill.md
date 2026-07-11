# Setup Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a one-time onboarding wizard that guides a new team member from zero to a running harness with a connected target repo and a clean test tick.

**Architecture:** A markdown skill file (`harness/skills/setup.md`) that Claude reads and follows as a sequential phase checklist. Each phase inspects observable filesystem/process state to determine if it can be skipped (idempotent). A `.claude/commands/setup.md` slash command provides the returning-user entry point. A README onboarding one-liner covers fresh-machine setup.

**Tech Stack:** Bash, SQLite (sqlite3 CLI), Claude Code skill/command markdown, curl (for API validation)

---

## File Map

| Action | Path | Responsibility |
|--------|------|---------------|
| Create | `harness/skills/setup.md` | The wizard skill — all 7 phases |
| Create | `.claude/commands/setup.md` | `/setup` slash command entry point |
| Modify | `harness/db/schema.sql` | Seed `last_sync_at = now` instead of hardcoded 2024 date |
| Modify | `README.md` | Add fresh-machine onboarding one-liner |
| Modify | `.gitignore` | Add `harness/workspace/` |

---

### Task 1: Fix `last_sync_at` seed in schema.sql

The schema currently seeds `last_sync_at` to `2024-01-01T00:00:00Z`. This causes all pollers to fetch full history on first tick. Change it to seed `now`.

**Files:**
- Modify: `harness/db/schema.sql:51-53`

- [ ] **Step 1: Open schema.sql and locate the seed insert**

```bash
grep -n "last_sync_at" harness/db/schema.sql
```
Expected output: line showing `'2024-01-01T00:00:00Z'`

- [ ] **Step 2: Replace the hardcoded date with datetime('now')**

Change line 51-53 from:
```sql
INSERT OR IGNORE INTO sync_state (id, last_sync_at, updated_at)
VALUES ('global', '2024-01-01T00:00:00Z', datetime('now'));
```
To:
```sql
INSERT OR IGNORE INTO sync_state (id, last_sync_at, updated_at)
VALUES ('global', datetime('now'), datetime('now'));
```

- [ ] **Step 3: Verify by running init on a temp DB**

```bash
sqlite3 /tmp/test-harness.db < harness/db/schema.sql
sqlite3 /tmp/test-harness.db "SELECT last_sync_at FROM sync_state WHERE id='global';"
```
Expected: today's date (not `2024-01-01`)

- [ ] **Step 4: Clean up temp DB**

```bash
rm /tmp/test-harness.db
```

- [ ] **Step 5: Commit**

```bash
git add harness/db/schema.sql
git commit -m "fix: seed last_sync_at to now so first tick doesn't backfill history"
```

---

### Task 2: Add harness/workspace/ to .gitignore

The target repo will be cloned to `harness/workspace/` — it must be gitignored.

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Add the entry**

Append to `.gitignore`:
```
harness/workspace/
```

- [ ] **Step 2: Verify**

```bash
cat .gitignore
```
Expected:
```
.worktrees/
harness/db/harness.db
harness/workspace/
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: gitignore harness/workspace (target repo checkout)"
```

---

### Task 3: Add fresh-machine onboarding one-liner to README.md

New team members need a single prompt to paste into Claude Code before the harness is cloned.

**Files:**
- Modify: `README.md` (create if absent)

- [ ] **Step 1: Check if README.md exists**

```bash
ls README.md 2>/dev/null && echo "exists" || echo "absent"
```

- [ ] **Step 2: Add or create README.md with onboarding section**

If absent, create `README.md`:
```markdown
# Orchestration Harness

A skill-driven, loop-based orchestrator. Polls Notion/Slack/GitHub, queues Events, dispatches agent Sessions.

## Onboarding

**New team member? Paste this into any Claude Code session:**

> Clone `https://github.com/<your-org>/orchestration-harness-v2` and run `harness/skills/setup.md`

This will guide you through the full setup: credentials, database, target repo, and a test tick.

**Already set up?** Open Claude Code inside the cloned harness and run `/setup` to resume or reconfigure.
```

If README.md already exists, add the `## Onboarding` section above to it.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add onboarding one-liner for fresh-machine setup"
```

---

### Task 4: Create .claude/commands/setup.md (slash command)

The `/setup` slash command is the returning-user entry point. It simply tells Claude to read and follow the setup skill.

**Files:**
- Create: `.claude/commands/setup.md`

- [ ] **Step 1: Create the commands directory if absent**

```bash
mkdir -p .claude/commands
```

- [ ] **Step 2: Write the command file**

Create `.claude/commands/setup.md`:
```markdown
Read and follow `harness/skills/setup.md` exactly, starting from the first incomplete phase.
```

- [ ] **Step 3: Verify Claude Code picks it up**

```bash
ls .claude/commands/
```
Expected: `setup.md`

- [ ] **Step 4: Commit**

```bash
git add .claude/commands/setup.md
git commit -m "feat: add /setup slash command entry point"
```

---

### Task 5: Write harness/skills/setup.md — Phase 1 & 2 (Clone harness + Configure env)

The core wizard skill. Write phases 1 and 2 first, then extend in Task 6.

**Files:**
- Create: `harness/skills/setup.md`

- [ ] **Step 1: Create the skill file with Phase 1**

Create `harness/skills/setup.md`:
````markdown
# Setup Wizard

Guide the team member through each phase in order. Before each phase, check whether it can be skipped by inspecting observable state (filesystem, process, API). Stop immediately on any failure — print the phase name, error, and exact remediation steps.

---

## Phase 1: Clone Harness

**Skip if:** you are already running inside the cloned harness repo (i.e., `harness/skills/setup.md` exists at the current path).

If not already inside the repo:
1. Ask the user: "What is the harness repo URL?"
2. Run:
   ```bash
   git clone <url> orchestration-harness-v2
   cd orchestration-harness-v2
   ```
3. Confirm `harness/skills/setup.md` now exists. If not, stop: "Clone succeeded but expected files not found — check the repo URL."

---

## Phase 2: Configure Env

**Skip if:** `harness/.env` exists AND all tokens pass full validation (run validation checks below — if all pass, print "Env already configured ✓" and move on).

Steps:
1. Print: "Let's configure your credentials. I'll ask for each value and validate it before writing the file."
2. For each variable in `harness/.env.example`, prompt the user: "Enter value for `<VAR_NAME>`:" (show the comment from `.env.example` as context).
3. After collecting all values, validate each service:

**Notion validation:**
```bash
# Validate token
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  https://api.notion.com/v1/users/me
# Expect: 200
```
```bash
# Validate database ID
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  https://api.notion.com/v1/databases/$NOTION_DATABASE_ID
# Expect: 200
```
```bash
# Validate agent user ID
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  https://api.notion.com/v1/users/$NOTION_AGENT_USER_ID
# Expect: 200
```

**Slack validation:**
```bash
curl -s -X POST https://slack.com/api/auth.test \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d['ok'] else d['error'])"
# Expect: ok
```
```bash
curl -s "https://slack.com/api/conversations.info?channel=$SLACK_CHANNEL_ID" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d['ok'] else d['error'])"
# Expect: ok
```

**GitHub validation:**
```bash
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/repos/$GITHUB_REPO
# Expect: 200
```

4. If any validation fails: re-prompt the specific failing variable. Retry up to 3 times. On third failure, stop with:
   - Notion token: https://www.notion.so/profile/integrations
   - Slack token: https://api.slack.com/apps
   - GitHub token: https://github.com/settings/tokens

5. Write all values to `harness/.env`:
```bash
cat > harness/.env <<EOF
NOTION_API_KEY=$NOTION_API_KEY
NOTION_DATABASE_ID=$NOTION_DATABASE_ID
NOTION_AGENT_USER_ID=$NOTION_AGENT_USER_ID
SLACK_BOT_TOKEN=$SLACK_BOT_TOKEN
SLACK_CHANNEL_ID=$SLACK_CHANNEL_ID
GITHUB_TOKEN=$GITHUB_TOKEN
GITHUB_REPO=$GITHUB_REPO
EOF
```
6. Print: "Credentials validated and written to harness/.env ✓"
````

- [ ] **Step 2: Verify the file was created**

```bash
wc -l harness/skills/setup.md
```
Expected: > 50 lines

- [ ] **Step 3: Commit**

```bash
git add harness/skills/setup.md
git commit -m "feat: setup skill phases 1-2 (clone harness, configure env)"
```

---

### Task 6: Extend setup.md — Phases 3–5 (Init DB, Clone workspace, Detect stack)

**Files:**
- Modify: `harness/skills/setup.md`

- [ ] **Step 1: Append Phase 3 to harness/skills/setup.md**

```markdown
---

## Phase 3: Init DB

**Skip if:** `harness/db/harness.db` exists AND `SELECT last_sync_at FROM sync_state WHERE id='global'` returns a value from today or later.

```bash
bash harness/db/init.sh
```

Verify:
```bash
sqlite3 harness/db/harness.db "SELECT last_sync_at FROM sync_state WHERE id='global';"
```
Expected: today's date/time (not `2024-01-01`).

Print: "Database initialized ✓"
```

- [ ] **Step 2: Append Phase 4**

```markdown
---

## Phase 4: Clone Target Repo

**Skip if:** `harness/workspace/` exists and contains a valid git repo (`git -C harness/workspace rev-parse HEAD` succeeds). If so, run `git -C harness/workspace pull` and print "Workspace up to date ✓".

Steps:
1. Ask: "What is the target repo URL? (This is the project the harness will orchestrate)"
2. Run:
   ```bash
   git clone <url> harness/workspace
   ```
3. Extract the repo name for GITHUB_REPO:
   ```bash
   GITHUB_REPO=$(git -C harness/workspace remote get-url origin \
     | sed 's/.*github.com[:/]\(.*\)\.git/\1/' \
     | sed 's/.*github.com[:/]\(.*\)/\1/')
   echo "GITHUB_REPO=$GITHUB_REPO"
   ```
4. Update `GITHUB_REPO` in `harness/.env`:
   ```bash
   python3 -c "
import re, pathlib, os
p = pathlib.Path('harness/.env')
p.write_text(re.sub(r'^GITHUB_REPO=.*', 'GITHUB_REPO=' + os.environ['GITHUB_REPO'], p.read_text(), flags=re.MULTILINE))
"
   ```
5. Print: "Target repo cloned to harness/workspace ✓  GITHUB_REPO=$GITHUB_REPO"
```

- [ ] **Step 3: Append Phase 5**

```markdown
---

## Phase 5: Detect & Start Stack

Stack detection (check in this order, stop at first match):
1. `package.json` present → likely Node. Check `scripts.dev`, `scripts.start` in package.json. Prefer `dev` over `start`.
2. `pyproject.toml` present → likely Python. Look for `[tool.taskipy]`, `[tool.poetry.scripts]`, or a `Makefile` with a `run`/`serve` target.
3. `Makefile` present → inspect targets. Look for `run`, `serve`, `dev`, `start`.
4. None matched → ask: "I couldn't detect a start command. What command starts the dev server for this project?"

If multiple signals are present (e.g., both `package.json` and `pyproject.toml`), ask: "I found multiple project files. Which component should I start? Options: [list detected options]"

Once command is determined:
1. Print the inferred command and ask: "I'll run `<command>` to start the dev server. Does that look right? (yes/no)"
2. If no, ask: "What command should I run instead?"
3. Run the confirmed command in the background, redirecting output to `harness/workspace/.dev-server.log`:
   ```bash
   cd harness/workspace && <command> > .dev-server.log 2>&1 &
   echo $! > ../.dev-server.pid
   ```
4. Watch `.dev-server.log` for readiness signals every 5 seconds:
   ```bash
   # Poll for up to 3 minutes (36 × 5s)
   for i in $(seq 1 36); do
     if grep -qiE "ready|listening|started|localhost|0\.0\.0\.0|port [0-9]+" harness/workspace/.dev-server.log 2>/dev/null; then
       echo "Dev server ready ✓"
       break
     fi
     if [ $i -eq 6 ] || [ $i -eq 12 ] || [ $i -eq 18 ] || [ $i -eq 24 ] || [ $i -eq 30 ]; then
       echo "Still waiting for dev server to start... ($(( i * 5 ))s elapsed)"
     fi
     sleep 5
   done
   ```
5. If no readiness signal after 3 minutes: stop with:
   - Command run: `<command>`
   - Log tail: last 20 lines of `.dev-server.log`
   - Action: "Check the log at `harness/workspace/.dev-server.log` and restart manually, then re-run `/setup`"
```

- [ ] **Step 4: Commit**

```bash
git add harness/skills/setup.md
git commit -m "feat: setup skill phases 3-5 (init DB, clone workspace, detect stack)"
```

---

### Task 7: Extend setup.md — Phases 6–7 (Test tick + Done)

**Files:**
- Modify: `harness/skills/setup.md`

- [ ] **Step 1: Append Phase 6**

```markdown
---

## Phase 6: Test Tick

Run one full tick to confirm all pollers connect and the system is healthy. Because `last_sync_at` was seeded to now, expect zero or very few events — that is the success case.

Steps:
1. Load env:
   ```bash
   set -a && source harness/.env && set +a
   ```
2. Clear any stale tick lock (safe during setup — no legitimate tick is running):
   ```bash
   sqlite3 harness/db/harness.db "DELETE FROM tick_lock WHERE id='global';"
   ```
3. Follow `harness/skills/sync-state.md` to acquire the tick lock.
3. Follow `harness/skills/poll-notion.md`. If it fails: release lock, stop — print the error and which env var to check.
4. Follow `harness/skills/poll-slack.md`. If it fails: release lock, stop.
5. Follow `harness/skills/poll-github.md`. If it fails: release lock, stop.
6. Follow `harness/skills/dispatch.md`. (With no events, this is a no-op — that is expected.)
7. Follow `harness/skills/sync-state.md` to update `last_sync_at` and release lock.
8. Print: "Test tick complete ✓ — pollers connected, no errors"
```

- [ ] **Step 2: Append Phase 7**

```markdown
---

## Phase 7: Done

Print setup summary:

```
╔══════════════════════════════════════════╗
║         Harness Setup Complete ✓         ║
╠══════════════════════════════════════════╣
║ Env:       harness/.env (all validated)  ║
║ DB:        harness/db/harness.db         ║
║ Workspace: harness/workspace/            ║
║ Repo:      <GITHUB_REPO>                 ║
║ Dev server: running                      ║
║ Test tick: clean                         ║
╚══════════════════════════════════════════╝

Next: run /loop to start the orchestrator.
```
```

- [ ] **Step 3: Commit**

```bash
git add harness/skills/setup.md
git commit -m "feat: setup skill phases 6-7 (test tick, done summary)"
```

---

### Task 8: Smoke test the full skill (manual)

No automated tests exist for skill markdown files — verify by reading through the completed skill and checking each phase against the spec.

**Files:**
- Read: `harness/skills/setup.md`
- Read: `docs/superpowers/specs/2026-06-02-setup-skill-design.md`

- [ ] **Step 1: Read the completed skill**

```bash
cat harness/skills/setup.md
```

- [ ] **Step 2: Verify each spec requirement is covered**

Check each item:
- [ ] Phase 1: skips if already inside repo, clones otherwise
- [ ] Phase 2: prompts all vars from `.env.example`, full validation per service, re-prompts up to 3 times with reference URLs
- [ ] Phase 3: runs `init.sh`, verifies `last_sync_at` is today
- [ ] Phase 4: clones to `harness/workspace/`, sets `GITHUB_REPO` in `.env`, handles already-cloned case
- [ ] Phase 5: detection priority order, handles ambiguous case, confirms command with user, 3-min timeout with 30s progress updates
- [ ] Phase 6: full tick, stops and releases lock on poller failure
- [ ] Phase 7: prints summary with all key values
- [ ] Resumability: each phase has a skip condition based on observable state

- [ ] **Step 3: Verify .gitignore has harness/workspace/**

```bash
grep "harness/workspace" .gitignore
```
Expected: `harness/workspace/`

- [ ] **Step 4: Verify slash command exists**

```bash
cat .claude/commands/setup.md
```

- [ ] **Step 5: Final commit if any fixes were made**

```bash
git add -p
git commit -m "fix: setup skill corrections from smoke test"
```

---

## NOT in scope

- Port-based dev server health check — deferred to TODOS.md; per-project log formats make detection unreliable
- Multi-project harness support — v1 constraint, one workspace only
- Automated integration tests for skill markdown — not feasible

## What already exists

- `harness/db/init.sh` + `schema.sql` — reused directly in Phase 3 ✓
- `harness/skills/sync-state.md`, `poll-*.md`, `dispatch.md` — reused verbatim in Phase 6 ✓

## Implementation Tasks

- [ ] **T1 (P2, human: ~5min / CC: ~1min)** — Phase 5 — Remove broken skip condition
  - Surfaced by: Architecture Review — skip relied on log file that may not exist
  - Files: `harness/skills/setup.md` (Task 6 Phase 5 content)
  - Verify: Phase 5 section has no "Skip if" preamble
- [ ] **T2 (P2, human: ~2min / CC: ~1min)** — Phase 4 — Replace sed with Python one-liner
  - Surfaced by: Code Quality Review — sed -i '' silently corrupts on Linux
  - Files: `harness/skills/setup.md` (Task 6 Phase 4 content)
  - Verify: No `sed -i` in setup.md
- [ ] **T3 (P1, human: ~2min / CC: ~1min)** — Phase 6 — Clear stale tick lock before test tick
  - Surfaced by: Failure Modes — stale lock from prior failed tick causes confusing first-run failure
  - Files: `harness/skills/setup.md` (Task 7 Phase 6 content)
  - Verify: Phase 6 includes `DELETE FROM tick_lock` before lock acquire

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | — | — |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR (PLAN) | 3 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

**UNRESOLVED:** 0
**VERDICT:** ENG CLEARED — ready to implement.
