---
type: reference
last_verified: 2026-05-20
owner: orchestrator-installer
---

# workflow-md Skill

`WORKFLOW.md` configures the orchestrator daemon. This skill covers reading, writing, and validating WORKFLOW.md files.

## Structure

WORKFLOW.md has two parts separated by `---`:
1. YAML frontmatter (config)
2. Liquid template prompt body

The config is parsed by `reference/typescript/src/config.ts` using the `WorkflowConfigSchema` Zod schema.

## Required frontmatter fields

```yaml
tracker: notion | linear | jira | github
candidate_states: [list of strings]
terminal_states: [list of strings]
max_concurrency: integer
poll_interval_seconds: integer
max_turns: integer
permission_mode: acceptEdits | bypassPermissions
model: haiku | sonnet | opus
max_budget_usd: float
workspace_root: string (relative path)
```

## Liquid template variables

Available in the prompt body:

| Variable | Example value |
|----------|--------------|
| `{{ ticket.identifier }}` | `NOTION-abc123` |
| `{{ ticket.title }}` | `Add dark mode` |
| `{{ ticket.url }}` | `https://notion.so/...` |
| `{{ ticket.state }}` | `In Progress` |
| `{{ ticket.priority }}` | `2` |
| `{{ workspace_path }}` | `/repo/.workspaces/notion-NOTION-abc123` |
| `{{ repo_root }}` | `/repo` |

## Validation

The Liquid renderer uses strict mode: undefined variables throw a render error. Always test the template by running the orchestrator against a real ticket before deploying.

## Hot reload

The orchestrator watches WORKFLOW.md with chokidar and reloads on change. Hot reload applies on the next poll tick — it does NOT interrupt running sessions.

## Editing safely

- Change `candidate_states` only when no sessions are dispatched (check `ps aux | grep "npm run dev"`).
- Changing `max_concurrency` takes effect immediately on next tick.
- Changing `permission_mode` requires a daemon restart if you want it to apply to already-running sessions (not recommended — let them finish).
