# Architecture Specification: Partial Migration Recovery

## 1. Architectural Layers
```text
Migration Runner (Fluent AsyncMigration)
       │
       ▼
HardenPasswordResetTokens.prepare(on: Database)
       │
       ├── Dialect Detection (PostgreSQL / MySQL / SQLite)
       │
       ├── Independent Column Reconciliation
       │     ├── Check & Add missing: code_hash
       │     ├── Check & Add missing: session_token_hash
       │     ├── Check & Add missing: code_expires_at
       │     ├── Check & Add missing: session_expires_at
       │     └── Check & Add missing: created_at
       │
       ├── Data Remediation
       │     └── Invalidate active legacy tokens (SET used = true)
       │
       ├── Column Deprecation
       │     └── Drop legacy columns (code, sessionToken, codeExpiresAt, sessionExpiresAt)
       │
       └── Index Reconciliation
             ├── Email lookup index
             ├── Code expiration lookup index
             └── Unique session token hash index
```

## 2. Dialect Specific Mechanics
### PostgreSQL:
- Uses native `ALTER TABLE password_reset_tokens ADD COLUMN IF NOT EXISTS <col> <type>` for each column.
- Single command:
  ```sql
  ALTER TABLE password_reset_tokens
      ADD COLUMN IF NOT EXISTS code_hash VARCHAR(255),
      ADD COLUMN IF NOT EXISTS session_token_hash VARCHAR(255),
      ADD COLUMN IF NOT EXISTS code_expires_at TIMESTAMP,
      ADD COLUMN IF NOT EXISTS session_expires_at TIMESTAMP,
      ADD COLUMN IF NOT EXISTS created_at TIMESTAMP;
  ```
- Drops legacy columns with `DROP COLUMN IF EXISTS`.
- Creates indexes with `CREATE INDEX IF NOT EXISTS` and `CREATE UNIQUE INDEX IF NOT EXISTS`.

### MySQL:
- Queries `information_schema.COLUMNS` for all existing columns on `password_reset_tokens`.
- Iterates over required columns (`code_hash`, `session_token_hash`, `code_expires_at`, `session_expires_at`, `created_at`).
- For each missing column, executes `ALTER TABLE password_reset_tokens ADD COLUMN <col> <type> NULL`.
- Checks and drops legacy columns (`code`, `sessionToken`, `codeExpiresAt`, `sessionExpiresAt`).
- Checks `information_schema.STATISTICS` for existing index names before creating indexes.

### SQLite:
- Queries `PRAGMA table_info(password_reset_tokens)`.
- Checks each of the 5 required columns individually; if missing, runs `ALTER TABLE password_reset_tokens ADD COLUMN <col> TEXT`.
- Drops legacy columns with `ALTER TABLE password_reset_tokens DROP COLUMN <col>`.
- Creates indexes with `CREATE INDEX IF NOT EXISTS` and `CREATE UNIQUE INDEX IF NOT EXISTS`.
