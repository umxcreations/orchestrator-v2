#!/usr/bin/env bash
set -euo pipefail
DB="${1:-harness/db/harness.db}"
echo "Initializing DB at $DB"
sqlite3 "$DB" < harness/db/schema.sql
echo "Done. Tables:"
sqlite3 "$DB" ".tables"
