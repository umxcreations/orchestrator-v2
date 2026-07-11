---
type: plan
last_verified: 2026-06-02
owner: agent
status: active
---

# Polling Orchestration Harness — Design Spec

**Date:** 2026-06-02  
**Status:** Design reviewed — ready for implementation

---

## §1 Goals

Build a simple, agent-friendly orchestration harness that:

- Uses a `/loop` as the orchestrator — no Node.js daemon, no webhook server, no local proxy
- Polls Notion, Slack, and GitHub on a shared `last_sync_at` timestamp
- Treats Notion tickets as the source of truth for work items — every context key is a Notion ticket Entity ID
- Allows work to originate from Slack conversations or Notion comments; Slack poller creates stub tickets inline
- Links all cross-system entities (Slack thread → Notion ticket → GitHub PR) in a local SQLite registry
- Is generic enough to apply to any project; configured and used by an agent

---

## §2 Architecture

```
┌─────────────────────────────────────────────────┐
│                  /loop tick                      │
│                                                  │
│  [tick start: check tick_lock, bail if locked]   │
│  [acquire tick_lock]                             │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
│  │  Notion  │  │  Slack   │  │   GitHub     │  │
│  │  Poller  │  │  Poller  │  │   Poller     │  │
│  └────┬─────┘  └────┬─────┘  └──────┬───────┘  │
│       └─────────────┴────────────────┘          │
│                      │                           │
│               last_sync_at                       │
│            (shared, SQLite)                      │
│                      │                           │
│                      ▼                           │
│              ┌───────────────┐                   │
│              │  Event Queue  │  (SQLite)         │
│              └───────┬───────┘                   │
│                      │                           │
│                      ▼                           │
│              ┌───────────────┐                   │
│              │   Dispatcher  │                   │
│              │ (model-driven)│                   │
│              └───────┬───────┘                   │
│                      │                           │
│                      ▼                           │
│         Subagent (via Agent tool)                │
│      reads context → reasons → acts freely       │
│                                                  │
│  [tick end: update last_sync_at, release lock]   │
└─────────────────────────────────────────────────┘
```

**Key principle:** The `/loop` IS the orchestrator. No daemon, no server. Each tick: acquire lock → poll → queue → dispatch → act → release lock.

**Tick interval:** Set `/loop` interval ≥ expected max session duration (e.g., `/loop 5m`) to avoid re-entrancy. The Tick Lock provides a hard guard with a 30-minute stale threshold.

**Tick atomicity:** If any poller fails, the entire tick fails — `last_sync_at` is not updated, the Tick Lock is released, and everything retries next tick. Deterministic Event IDs make re-polling safe.

---

## §3 SQLite Schema

### `sync_state` — shared last-sync timestamp

```sql
CREATE TABLE sync_state (
  id TEXT PRIMARY KEY DEFAULT 'global',
  last_sync_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

Single row. Updated only on successful tick completion.

### `tick_lock` — re-entrancy guard

```sql
CREATE TABLE tick_lock (
  id TEXT PRIMARY KEY DEFAULT 'global',
  locked_at TEXT NOT NULL,
  locked_by TEXT NOT NULL   -- tick ID for debugging
);
```

Single row. Acquired at tick start, released at tick end (success or failure). If `locked_at` is older than 30 minutes, treat as stale and clear it before proceeding.

### `events` — normalized signals from all sources

```sql
CREATE TABLE events (
  id TEXT PRIMARY KEY,       -- deterministic: derived from source + external_id
  source TEXT NOT NULL,      -- "notion" | "slack" | "github"
  type TEXT NOT NULL,        -- see §8 for v1 event types
  context_key TEXT NOT NULL, -- Notion ticket entity ID (always)
  payload TEXT NOT NULL,     -- JSON raw data from source
  status TEXT NOT NULL DEFAULT 'pending',  -- pending | processing | done | ignored
  received_at TEXT NOT NULL,
  processed_at TEXT
);
```

Event IDs are deterministic (e.g., `slack-C123-1234567890`) so duplicate inserts fail safely on the primary key constraint — no extra dedup logic needed.

### `entities` — one row per external entity

```sql
CREATE TABLE entities (
  id TEXT PRIMARY KEY,          -- internal UUID
  source TEXT NOT NULL,         -- "notion" | "slack" | "github"
  external_id TEXT NOT NULL,    -- ID in that system
  type TEXT NOT NULL,           -- "ticket" | "thread" | "pr" | "comment"
  url TEXT,
  created_at TEXT NOT NULL
);
```

### `links` — cross-system relationships

```sql
CREATE TABLE links (
  entity_a TEXT NOT NULL REFERENCES entities(id),
  entity_b TEXT NOT NULL REFERENCES entities(id),
  relationship TEXT NOT NULL,   -- "originated_from" | "implements" | "discussed_in"
  created_at TEXT NOT NULL,
  created_by TEXT NOT NULL      -- session ID that created the link
);
```

### `sessions` — agent session tracking

```sql
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  context_key TEXT NOT NULL,    -- Notion ticket entity ID
  status TEXT NOT NULL,         -- scheduled | running | completed | cancelled
  intent TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

---

## §4 Cross-System Entity Linking

The context key is **always a Notion ticket Entity ID**. No temporary roots, no type-switching.

**Example flow:**

1. Slack message tagged `@agent` in configured channel
   → Slack poller creates stub Notion ticket (title: "From Slack: [timestamp]", no body)
   → create entity: `{ source: "slack", external_id: "C123/1234567890", type: "thread" }`
   → create entity: `{ source: "notion", external_id: "abc-page-id", type: "ticket" }`
   → create link: `slack_entity → notion_entity, relationship: "originated_from"`
   → write event with `context_key = notion_entity.id`
2. Agent session picks up the ticket, enriches title/body as its first action
3. Agent opens GitHub PR
   → create entity: `{ source: "github", external_id: "owner/repo#42", type: "pr" }`
   → create link: `notion_entity → github_entity, relationship: "implements"`

Any entity in the chain can resolve all related entities. The Dispatcher uses this graph to avoid spawning duplicate sessions for the same work item.

---

## §5 Poll Cycle (per `/loop` tick)

1. Check `tick_lock` — if locked and < 30 min old, bail immediately
2. Acquire `tick_lock`
3. Read `last_sync_at` from `sync_state`
4. Poll in parallel (if any poller fails, abort — release lock, do not update `last_sync_at`):
   - **Notion:** pages and comments modified since `last_sync_at` where assigned to agent or body contains `@agent`
   - **Slack:** messages in configured channel since `last_sync_at` where text mentions `@agent` — create stub Notion ticket if no ticket linked to the thread yet
   - **GitHub:** PRs updated since `last_sync_at` on agent-opened branches — capture `pr.review_commented`, `pr.merged`, `pr.closed`
5. For each result: look up or create entity record, write normalized event (duplicate inserts ignored via deterministic ID)
6. Pass `pending` events to Dispatcher
7. Update `last_sync_at` to now
8. Release `tick_lock`

---

## §6 Dispatcher

1. Read all `pending` events, group by `context_key` (always a Notion ticket entity ID)
2. Check `sessions` table — if a session is `running` for this context, skip
3. Spawn subagent via the `Agent` tool with injected context:
   - The triggering event payload
   - All linked entities and their external URLs
   - Current Notion ticket content
   - Recent Slack thread (if applicable)
   - List of available skills the agent may invoke
4. Agent reasons freely — determines action autonomously based on context
5. Agent writes outcomes back: Notion status/comments (last), Slack thread reply, GitHub PR
6. Agent updates `sessions` and `links` tables on completion

---

## §7 Agent Behavior

The agent has maximum freedom — it reads context, reasons about what to do, and pulls skills as needed. The Dispatcher does not prescribe behavior.

**Blocked state:** When the agent cannot proceed without human input, it must:
1. Post a Slack message to the originating thread explaining what it needs
2. Set Notion ticket status to `Blocked`

The harness resumes the work item when the human replies with `@agent` in that thread.

**Notion as commit point:** The agent updates the Notion ticket status as its *last* action. A successful Notion write is the signal that work is complete.

**Skills:** Human-authored markdown files. The agent can invoke them but cannot create or modify them in v1. A future meta-loop will review sessions and evolve skills.

---

## §8 Trigger Convention & Event Types

The `@agent` mention is the universal trigger across all systems:

| System | Trigger |
|--------|---------|
| Slack | `@agent` mention in the configured channel |
| Notion | `@agent` in a page comment, or ticket assigned to the agent user |
| GitHub | Not a trigger source — agent polls GitHub for status only |

**v1 Event types:**

| Type | Source | Agent action |
|------|--------|-------------|
| `ticket.created` | Notion | Enrich and begin work |
| `comment.tagged` | Notion | Respond to comment |
| `message.tagged` | Slack | Create stub ticket, begin work |
| `pr.review_commented` | GitHub | Reason about comment — fix, respond, or flag |
| `pr.merged` | GitHub | Set Notion ticket → `Done` |
| `pr.closed` | GitHub | Set Notion ticket → `Blocked` + Slack notification |

---

## §9 Notion as Status Layer

Every Notion ticket managed by the agent carries these properties:

| Property | Values |
|----------|--------|
| `Agent Status` | `Queued` → `In Progress` → `Done` / `Blocked` |
| `Agent Session ID` | Internal session ID |
| `Last Agent Update` | ISO timestamp |
| `GitHub PR` | URL when applicable |
| `Slack Thread` | URL to originating thread when applicable |

These are the human-visible status layer. SQLite is the machine-readable layer.

---

## §10 Project Structure

```
harness/
  skills/
    poll-notion.md       ← Notion API polling instructions
    poll-slack.md        ← Slack API polling + stub ticket creation
    poll-github.md       ← GitHub API polling instructions
    dispatch.md          ← Dispatcher logic
    sync-state.md        ← last_sync_at + tick_lock management
    entity-registry.md   ← how to create/link entities
  db/
    schema.sql           ← full SQLite schema
    init.sh              ← one-time DB initialization
  CLAUDE.md              ← L1 routing table
  .env.example           ← required API keys
```

No TypeScript daemon. No build step. Skills are the implementation — readable and executable by the agent.

---

## §11 Configuration

Required environment variables (`.env`):

```
ANTHROPIC_API_KEY=
NOTION_API_KEY=
NOTION_DATABASE_ID=       # the tickets database
SLACK_BOT_TOKEN=
SLACK_CHANNEL_ID=         # the single channel to watch
GITHUB_TOKEN=
GITHUB_REPO=              # owner/repo (single repo only in v1)
```

---

## §12 Non-Goals

- No real-time event delivery (acceptable latency: poll interval)
- No multi-channel Slack monitoring (single configured channel only)
- No webhook ingestion (no public endpoint required)
- No TypeScript build pipeline
- No auto-deploy (agent can open PRs; merge/deploy is human-controlled)
- No multi-repo GitHub support (single repo only)
- No agent-authored skills (human-authored only in v1)
- No partial tick commits (tick is all-or-nothing)
