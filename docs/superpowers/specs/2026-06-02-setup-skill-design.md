# Setup Skill Design

**Date:** 2026-06-02  
**Status:** Approved

## Overview

A one-time onboarding wizard for new team members. Walks the user through cloning the harness, configuring credentials, initializing the database, cloning and starting the target repo, and running a test tick to confirm everything works end-to-end.

Not part of the `/loop` tick sequence — setup is manual and runs once per project onboarding.

## Entry Points

Two entry points depending on machine state:

- **Fresh machine** (harness not yet cloned): team member opens any Claude Code session and pastes the prompt from `README.md`: `"Clone <repo-url> and run harness/skills/setup.md"`. Claude clones the harness then continues with the remaining phases.
- **Returning / resuming**: team member opens a Claude Code session inside the cloned harness and runs `/setup` (the `.claude/commands/setup.md` slash command).

## Files

| Path | Purpose |
|------|---------|
| `harness/skills/setup.md` | The wizard skill — sequential phase checklist |
| `.claude/commands/setup.md` | Slash command entry point — invokes the skill |
| `README.md` | Contains the fresh-machine onboarding one-liner |

## Phase Sequence

Phases run in order. Any failure stops the wizard immediately.

1. **Clone harness** — skip if already inside the cloned repo. Otherwise clone to a local path and `cd` into it.
2. **Configure env** — for each var in `harness/.env.example`, prompt the user for the value. After all values are entered, validate full config per service:
   - **Notion**: token works + `NOTION_DATABASE_ID` resolves to a real database + `NOTION_AGENT_USER_ID` is a valid user
   - **Slack**: `auth.test` passes + `SLACK_CHANNEL_ID` is accessible by the bot
   - **GitHub**: token works + `GITHUB_REPO` is accessible
   Write to `harness/.env` only after all validations pass. Re-prompt the specific failing value up to 3 times before stopping with a reference URL.
3. **Init DB** — run `harness/db/init.sh` to create/migrate `harness.db`. Seeds `last_sync_at = now` so the first tick only picks up new activity (no backlog flood).
4. **Clone target repo** — prompt for the target repo URL. Clone to `harness/workspace/` (gitignored). Set `GITHUB_REPO` in `.env` from the cloned repo's remote.
5. **Detect & start stack** — inspect the target repo using priority order: `package.json` → `pyproject.toml` → `Makefile` → ask user. If multiple signals present, ask the user which component to start. Infer the start command, confirm with user, then run it. Watch stdout for readiness signals (port binding, "ready", "listening", "started"). Progress update every 30 seconds. 3-minute timeout — on timeout, stop with the command run and what to check.
6. **Test tick** — run one full tick (poll all sources → dispatch) against the live target. Because `last_sync_at` was seeded to now, expect zero or very few events. Confirm pollers connect and tick completes without errors.
7. **Done** — print summary: env written, DB ready, target repo running at `<path>`, first tick clean.

## Error Handling & Resumability

- **Idempotent phases** — re-running the wizard is safe:
  - If `.env` already exists: ask "found existing .env — overwrite or skip?"
  - If DB already initialized: skip `init.sh`
  - If target repo already cloned: `git pull` instead of clone
- **Stop on failure** — print the failed phase, error details, and exact remediation steps. Do not continue to the next phase.
- **No rollback** — completed phases stay done. Re-running picks up from the first incomplete phase by inspecting observable state: does `.env` exist and pass validation? does `harness.db` exist? does `harness/workspace/` exist? is the dev server responding? No stored progress state — the filesystem is the state.
- **Token validation** — re-prompt up to 3 times. On third failure, stop with a reference URL for obtaining the correct token.

## Success Criteria

Setup is complete when:
- `harness/.env` is populated and all tokens validated
- `harness/db/harness.db` exists and schema is current
- Target repo is checked out locally and its dev server is running
- One full test tick completes without errors
