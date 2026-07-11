# Orchestration Harness — Tick Entry Point

This file is the L1 routing table. Each `/loop` tick runs the sequence below.

## Tick Sequence

1. **sync-state**: Check and acquire tick lock → read `last_sync_at`
   - Skill: `harness/skills/sync-state.md`
   - If lock is active (< 30 min old): stop immediately, do not poll.

2. **Poll all sources** (if any poller fails, release lock and stop — do not update `last_sync_at`):
   - Notion: `harness/skills/poll-notion.md`
   - Slack: `harness/skills/poll-slack.md`
   - GitHub: `harness/skills/poll-github.md`

3. **Dispatch**: `harness/skills/dispatch.md`
   - Group pending events by context_key
   - Skip contexts with running sessions
   - Spawn one subagent per context_key

4. **sync-state**: Update `last_sync_at` → release tick lock

5. **self-improve** (runs only if harness is idle + 24h gate passes):
   - Skill: `harness/skills/self-improve.md`
   - Skips silently if: any pending/processing events, any running sessions, < 24h since last run, or circuit breaker active.
   - Failure in this step does NOT affect the tick. `ScheduleWakeup` has already been called in step 4.

## DB
All skills use: `harness/db/harness.db`

## Env vars required
See `.env.example`

## Glossary
See `CONTEXT.md` in the project root for domain terminology.

## Self-Improvement Notes (2026-06-04)

### Gap: No recovery guidance for browser snapshot loop
**Signal:** session 0576d92b: `take_snapshot` returned the same "Create Next App" page snapshot 3x (indices 401, 423, 434) and again 3x (indices 506, 517, 526) when `wait_for` timed out because of unexpected app behaviour (auto-archive on completion). Agent had to query the DB directly to diagnose.
**Category:** missing-recovery
**Suggestion:** Add to `harness/skills/e2e-test.md` Phase 3: "If `wait_for` times out and `take_snapshot` returns the same state on repeat calls, query the app's DB directly (`sqlite3 harness/workspace/*.db` or equivalent) to check actual data state before concluding the test step failed. App behaviour such as auto-archive, pagination, or filter-based hiding can cause elements to disappear from the DOM without being an error."
