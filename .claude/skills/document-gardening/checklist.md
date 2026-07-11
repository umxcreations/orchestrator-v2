---
type: reference
---

# Document Gardening Checklist

Quick reference for running a gardening pass.

## Pre-Audit Checklist

- [ ] Define path scope (which docs to scan?)
- [ ] Define stale indicators (what means "outdated"?)
- [ ] List exclusions (docs to skip)
- [ ] Identify high-priority docs (what blocks other work?)

## Per-Document Audit Checklist

For each doc:
- [ ] Read the full document
- [ ] Check `last_verified` date — is it within acceptable window?
- [ ] Verify file references still exist: `find cortex/ -name "referenced-file.ts"`
- [ ] Verify function/class names still exist: `grep -r "function_name" src/`
- [ ] Check for broken links: `grep "^\[.*\](.*)" doc.md` and spot-check
- [ ] Look for dated language ("coming soon", "TODO", "deprecated")
- [ ] Look for resolved "Known Gaps" that should be removed
- [ ] Determine status: Current | Update | Remove | Review
- [ ] Note specific issues in audit report

## Update Checklist (per doc to update)

- [ ] Verify current code state before making fixes
- [ ] Update stale references to match current paths
- [ ] Bump `last_verified` to today's date
- [ ] Remove resolved "Known Gaps" or outdated guidance
- [ ] Fix broken links
- [ ] Run spell check if applicable
- [ ] Write decision entry to `.beads/decisions.jsonl`
- [ ] Create single commit with clear message

## Removal Checklist (per doc to remove)

- [ ] Confirm with user: "Delete this doc?"
- [ ] Search entire repo for links to this doc: `grep -r "path/to/doc" .`
- [ ] Update all links in other docs
- [ ] Remove the file
- [ ] Write decision entry to `.beads/decisions.jsonl`
- [ ] Create single commit explaining why removed

## Report Checklist

- [ ] Total docs scanned
- [ ] Breakdown by status (Current | Update | Remove | Review)
- [ ] List each doc with its status
- [ ] List specific issues found (e.g., "3 docs have stale `last_verified`")
- [ ] Highlight removals that need user approval
- [ ] Highlight reviews that need user decision

## Post-Gardening Checklist

- [ ] All decisions logged to `.beads/decisions.jsonl`
- [ ] All commits made with clear messages
- [ ] User approved all removals
- [ ] Links verified after removals
- [ ] Tests still pass (if applicable)

## Common Stale Indicators — Quick Grep

```bash
# Docs with old last_verified
grep -l "last_verified: 202[0-4]" cortex/**/*.md

# Docs with "TODO" or "Coming soon"
grep -l "TODO\|Coming soon\|Not yet" cortex/**/*.md

# Docs with broken file references
# (requires manual verification, but find might help)
find cortex -name "*.md" -exec grep -l "cortex/" {} \;
```

## Decision Entry Template

```json
{
  "timestamp": "2026-05-24T14:30:00Z",
  "decision": "document-gardening",
  "doc_path": "cortex/CORTEX_SPEC.md",
  "action": "update",
  "reason": "Bumped last_verified to current date; confirmed all file references exist and are accurate",
  "changes": [
    "Updated last_verified from 2026-05-20 to 2026-05-24",
    "Verified all paths in §13 Project Structure match actual files"
  ]
}
```
