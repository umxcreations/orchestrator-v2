---
type: skill
last_verified: 2026-05-24
owner: harness
---

# Document Gardening Skill

Systematic approach to finding, auditing, updating, and removing outdated documentation. Use when you need to maintain docs as the codebase evolves.

## Step 1: Scope the Garden

Define what you're gardening:
- **Path pattern:** Where to search (e.g., `*.md`, `cortex/`, root level)
- **Stale indicators:** What makes a doc "outdated"? Examples:
  - `last_verified` timestamp > 30 days old
  - References to removed files/functions
  - Dated language ("coming soon", "TODO", "deprecated")
  - Known gaps section that got resolved
  - Version numbers that don't match current code
- **Exclusions:** Docs you don't want to touch (e.g., `.worktrees/`, archived ADRs, user's private notes)

## Step 2: Audit Pass

For each doc in scope:
1. **Read** the document fully
2. **Check** against stale indicators:
   - Is the `last_verified` date current?
   - Do file paths still exist?
   - Do referenced functions/classes still exist?
   - Does the guidance still apply?
   - Are there broken links or missing sections?
3. **Classify** as one of:
   - ✓ **Current** — no action needed
   - 🔄 **Update** — fixable with specific edits
   - 🗑️ **Remove** — no longer applies, outdated, superseded
   - ⚠️ **Review** — uncertain, needs user decision

## Step 3: Produce Audit Report

Create a structured report with one section per doc:

```
## path/to/doc.md
Status: [Current | Update | Remove | Review]
Last verified: YYYY-MM-DD
Issues found:
- (list specific staleness indicators)

Recommendation:
(brief explanation of why Current/Update/Remove/Review)
```

Include a summary at top:
- Total docs scanned
- Breakdown by status (count of each)
- High-priority items (docs that block other work)

## Step 4: Update Documents

For docs classified as **Update**:
1. **Verify the fix** — check current code state first
2. **Make edits** — update stale references, bump `last_verified`, remove resolved "known gaps"
3. **Test links** — verify any URLs still resolve
4. **Commit separately** — each doc update gets its own commit with reason

For docs classified as **Remove**:
1. **Double-check** — confirm it's truly obsolete (ask user if uncertain)
2. **Check references** — grep for links to this doc elsewhere
3. **Delete** — remove the file and update any links pointing to it
4. **Commit** — explain why (superseded by X, archived, no longer applies)

## Step 5: Document Decisions

Write to `.beads/decisions.jsonl` for each doc touched:

```json
{
  "timestamp": "2026-05-24T...",
  "decision": "document-gardening",
  "doc_path": "path/to/doc.md",
  "action": "update|remove|keep",
  "reason": "brief explanation",
  "changes": ["list of specific edits if update"]
}
```

This creates a history of what was gardened and why.

## Step 6: Review with User

Before committing removals:
1. Show the audit report
2. Ask: "Should I proceed with these changes?"
3. Get user approval on removals specifically
4. Proceed with updates and removals

## Staleness Patterns to Watch

| Pattern | Signal | Action |
|---------|--------|--------|
| `last_verified: 2025-01-15` | Older than 90 days | Check if still accurate |
| References `WORKFLOW.md` | File no longer exists | Update/remove reference |
| "Coming soon" or "TODO" | Future-looking language | Resolve or archive |
| `§14 Known Gaps` with resolved items | Gaps filled in code | Remove from gaps section |
| Broken links | 404s, wrong paths | Fix or remove |
| Mentions removed functions | Code archaeology needed | Verify obsolete, then remove |
| Version pinning (`v3.2.1`) | Version drifted | Update to current |
| Author/owner field outdated | Owner left, changed role | Update or mark for review |

## Example: Full Workflow

1. Scope: "All .md files in root and cortex/, exclude .worktrees/"
2. Audit: Find WORKFLOW.md references, old ORCHESTRATOR_SPEC.md, stale EVAL_SPEC.md
3. Report: "WORKFLOW.md removed, 3 docs have stale `last_verified`, 2 have broken links"
4. Update: Bump `last_verified` on current docs, fix link references, remove WORKFLOW.md mentions
5. Decide: Log each action to decisions.jsonl
6. Review: Show user the audit, ask for approval on deletions
7. Commit: One commit per doc with clear reason

## Rules

- **Never delete without asking first** — remove is a prohibited action; get user confirmation
- **Verify before fixing** — don't assume a reference is broken; check current code state
- **Link updates matter** — if you remove/move a doc, grep for all references and update them
- **Keep decisions logged** — decisions.jsonl is your audit trail
- **Batch by category** — commit all updates together, all removals together (but ask for approval on removals first)
