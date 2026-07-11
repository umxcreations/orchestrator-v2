---
type: reference
last_verified: 2026-05-20
owner: harness-installer
---

# Commit Skill

Use this skill when creating git commits. Follows the HARNESS_SPEC beads contract and `.claude/standards/git.md` conventions.

## Before committing

1. Check open beads: `tail -20 .beads/status.jsonl | grep in_progress`
2. Update the relevant bead's `notes` to reflect what you're committing.
3. Run tests if they exist.

## Commit message format

```
<type>(<scope>): <short description>

[optional body — what changed and why, not how]
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`

Scope: the component or file area (e.g., `notion-adapter`, `beads`, `hooks`)

Keep the subject line ≤72 characters.

## Staging

Stage specific files, not `git add -A`:
```bash
git add src/specific-file.ts tests/specific-file.test.ts
git status  # verify no unintended files staged
git commit -m "feat(notion): add fetchCandidateTickets() implementation"
```

## After committing

If this commit closes a bead, update it to `done` in `.beads/status.jsonl`.
