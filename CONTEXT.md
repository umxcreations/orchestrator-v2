# Polling Orchestration Harness

A skill-driven, loop-based orchestration harness that polls Notion, Slack, and GitHub to detect work items and dispatch agent sessions to act on them. No daemon, no server — the `/loop` is the orchestrator.

## Language

**Tick**: One execution cycle of the `/loop` — poll all sources, queue events, dispatch sessions, sync back. A tick is atomic from the harness's perspective.
_Avoid_: cycle, run, iteration

**Tick Lock**: A single-row database record asserting that a tick is currently executing. Prevents re-entrant ticks. Treated as stale and cleared if older than 30 minutes.
_Avoid_: lock, mutex, session lock

**Event**: A normalized signal written to the local database after polling an external source. Represents something that happened that may require agent action. Event IDs are deterministic, derived from `source + external_id` (e.g., `slack-C123-1234567890`) so duplicate inserts fail safely on the primary key constraint. Event types in v1: `ticket.created`, `comment.tagged`, `message.tagged` (Slack), `pr.review_commented`, `pr.merged`, `pr.closed` (GitHub).
_Avoid_: message, notification, trigger

**Entity**: A record representing a single external object (Slack thread, Notion ticket, GitHub PR) tracked in the local database. Each entity has one source and one external ID.
_Avoid_: item, resource, object

**Link**: A directed relationship between two Entities, capturing how work flowed across systems (e.g., a Slack thread originated a Notion ticket).
_Avoid_: relation, connection, reference

**Session**: A record representing one agent execution handling a specific work item. Tracks status from scheduled → running → completed/cancelled.
_Avoid_: job, task, run

**Blocked**: A Notion ticket status set by the agent when it cannot proceed without human input. Always paired with a Slack notification to the originating thread. The harness resumes the work item when the human replies with `@agent` in that thread.
_Avoid_: stuck, waiting, paused

**Dispatcher**: The logic within a tick that reads pending Events, resolves their Entity graph, and spawns Agent Sessions for contexts that don't already have a running Session. The Dispatcher injects rich context (ticket content, linked entities, triggering event, available skills list) but does not prescribe what the agent does — the agent reasons freely and pulls skills as needed. Skills are human-authored markdown files; the agent can invoke them but cannot create or modify them in v1.
_Avoid_: scheduler, router, orchestrator

**Workspace**: The local checkout of the target repository, located at `harness/workspace/`. Subagents spawned by the Dispatcher operate on the Workspace. Created once during setup; never committed to the harness repo.
_Avoid_: target repo, project folder, working directory

**Context Key**: The Notion ticket Entity ID that groups related Events and Sessions. Always a Notion ticket — never a Slack thread or PR. The Dispatcher groups by context key to avoid duplicate sessions for the same work. The Slack poller is responsible for creating a stub Notion ticket (and setting the context key) when work originates from Slack. The stub has a minimal title (e.g., "From Slack: [timestamp]") and no body — the agent enriches it as its first action.
_Avoid_: thread key, root ID, parent ID

**Improvement Run**: One execution of the self-improvement skill — analyzes Claude Code transcripts from the last 24 hours, identifies skill gaps, and appends suggestions to harness skill/doc files. Tracked in a flat file (`harness/db/self-improvement-last-run.txt`), not in SQLite. Distinct from a Session: no user work item, no context key, no Notion ticket.
_Avoid_: improvement session, maintenance run, optimization cycle
