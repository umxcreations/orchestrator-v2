# entity-registry

Instructions for creating, querying, and linking entities in the local SQLite registry.

## DB path
Always use: `harness/db/harness.db`

## Create an entity

Generate a UUID via `uuidgen` (or `python3 -c "import uuid; print(uuid.uuid4())"` on macOS).

```bash
ENTITY_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
sqlite3 harness/db/harness.db \
  "INSERT OR IGNORE INTO entities (id, source, external_id, type, url, created_at)
   VALUES ('$ENTITY_ID', '$SOURCE', '$EXTERNAL_ID', '$TYPE', '$URL', datetime('now'));"
```

Values for `source`: `notion` | `slack` | `github`
Values for `type`: `ticket` | `thread` | `pr` | `comment`

## Look up entity by external_id

```bash
sqlite3 harness/db/harness.db \
  "SELECT id, source, external_id, type, url FROM entities
   WHERE source='$SOURCE' AND external_id='$EXTERNAL_ID';"
```

## Create a link between two entities

```bash
SESSION_ID="<current session id>"
sqlite3 harness/db/harness.db \
  "INSERT OR IGNORE INTO links (entity_a, entity_b, relationship, created_at, created_by)
   VALUES ('$ENTITY_A_ID', '$ENTITY_B_ID', '$RELATIONSHIP', datetime('now'), '$SESSION_ID');"
```

Values for `relationship`: `originated_from` | `implements` | `discussed_in`

## Find all entities linked to a context_key (Notion ticket entity ID)

```bash
sqlite3 harness/db/harness.db \
  "SELECT e.id, e.source, e.external_id, e.type, e.url
   FROM entities e
   JOIN links l ON (l.entity_a = e.id OR l.entity_b = e.id)
   WHERE l.entity_a = '$CONTEXT_KEY' OR l.entity_b = '$CONTEXT_KEY';"
```
