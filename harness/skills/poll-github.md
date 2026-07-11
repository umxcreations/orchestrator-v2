# poll-github

Poll the configured GitHub repo for PRs updated since `last_sync_at` on agent-opened branches. Capture review comments, merges, and closes.

## Required env vars
- `GITHUB_TOKEN`
- `GITHUB_REPO`  — format: `owner/repo`

## Poll updated PRs

```bash
curl -s "https://api.github.com/repos/$GITHUB_REPO/pulls?state=all&sort=updated&direction=desc&per_page=50" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json"
```

Filter to PRs where `updated_at > last_sync_at`.

## For each PR

1. Look up entity by `source="github"`, `external_id="$GITHUB_REPO#$PR_NUMBER"`.
2. If entity not found, skip (only track agent-opened PRs; agent creates entity when opening PR).
3. If found, determine event type:
   - PR state is `closed` AND `merged=true` → `pr.merged`
   - PR state is `closed` AND `merged=false` → `pr.closed`
   - Otherwise → check for new review comments:

```bash
curl -s "https://api.github.com/repos/$GITHUB_REPO/pulls/$PR_NUMBER/comments" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json"
```

Filter to comments where `created_at > last_sync_at` → event type `pr.review_commented`.

4. Resolve context_key via entity graph:

```bash
sqlite3 harness/db/harness.db \
  "SELECT e2.id FROM links l
   JOIN entities e1 ON e1.id = l.entity_a
   JOIN entities e2 ON e2.id = l.entity_b
   WHERE e1.source='github' AND e1.external_id='$GITHUB_REPO#$PR_NUMBER' AND e2.source='notion'
   UNION
   SELECT e1.id FROM links l
   JOIN entities e1 ON e1.id = l.entity_a
   JOIN entities e2 ON e2.id = l.entity_b
   WHERE e2.source='github' AND e2.external_id='$GITHUB_REPO#$PR_NUMBER' AND e1.source='notion';"
```

5. Insert event with resolved context_key:
   - Event ID: `github-$GITHUB_REPO-$PR_NUMBER-<type>` (for comments: append comment ID)
   - Payload: PR JSON (or comment JSON for `pr.review_commented`)
