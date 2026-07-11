CREATE TABLE IF NOT EXISTS sync_state (
  id TEXT PRIMARY KEY DEFAULT 'global',
  last_sync_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tick_lock (
  id TEXT PRIMARY KEY DEFAULT 'global',
  locked_at TEXT NOT NULL,
  locked_by TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  type TEXT NOT NULL,
  context_key TEXT NOT NULL,
  payload TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  received_at TEXT NOT NULL,
  processed_at TEXT
);

CREATE TABLE IF NOT EXISTS entities (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  external_id TEXT NOT NULL,
  type TEXT NOT NULL,
  url TEXT,
  created_at TEXT NOT NULL,
  UNIQUE(source, external_id)
);

CREATE TABLE IF NOT EXISTS links (
  entity_a TEXT NOT NULL REFERENCES entities(id),
  entity_b TEXT NOT NULL REFERENCES entities(id),
  relationship TEXT NOT NULL,
  created_at TEXT NOT NULL,
  created_by TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  context_key TEXT NOT NULL,
  status TEXT NOT NULL,
  intent TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

INSERT OR IGNORE INTO sync_state (id, last_sync_at, updated_at)
VALUES ('global', datetime('now'), datetime('now'));
