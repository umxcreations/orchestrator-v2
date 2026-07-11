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

---

## Phase 2b: Provision Notion Database Properties

**Skip if:** all four required custom properties exist in the Notion database (`Agent Session ID`, `Last Agent Update`, `GitHub PR`, `Slack Thread`). `Status` is a built-in Notion property — no need to provision it.

Check:
```bash
source harness/.env
curl -s "https://api.notion.com/v1/databases/$NOTION_DATABASE_ID" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  | python3 -c "
import sys, json
props = set(json.load(sys.stdin).get('properties', {}).keys())
required = {'Agent Session ID', 'Last Agent Update', 'GitHub PR', 'Slack Thread'}
missing = required - props
print('missing: ' + ', '.join(sorted(missing)) if missing else 'all present')
"
```

If any are missing, add them:
```bash
curl -s -X PATCH "https://api.notion.com/v1/databases/$NOTION_DATABASE_ID" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d '{
    "properties": {
      "Agent Session ID": {"rich_text": {}},
      "Last Agent Update": {"date": {}},
      "GitHub PR": {"url": {}},
      "Slack Thread": {"url": {}}
    }
  }' | python3 -c "import sys,json; d=json.load(sys.stdin); print('Notion properties provisioned ✓' if d.get('object')=='database' else 'ERROR: '+str(d))"
```

If the PATCH returns an error, stop with: "Failed to provision Notion properties — check that the integration has write access to the database."

Print: "Notion database properties verified ✓"

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
4. Follow `harness/skills/poll-notion.md`. If it fails: release lock, stop — print the error and which env var to check.
5. Follow `harness/skills/poll-slack.md`. If it fails: release lock, stop.
6. Follow `harness/skills/poll-github.md`. If it fails: release lock, stop.
7. Follow `harness/skills/dispatch.md`. (With no events, this is a no-op — that is expected.)
8. Follow `harness/skills/sync-state.md` to update `last_sync_at` and release lock.
9. Print: "Test tick complete ✓ — pollers connected, no errors"

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

Next: start the orchestrator by running this command in Claude Code:

  /loop

This runs one tick per iteration (poll → dispatch → sync). Claude Code
will keep looping until you stop it with Ctrl+C or /exit.
```
