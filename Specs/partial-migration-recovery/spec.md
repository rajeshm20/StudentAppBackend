# Feature: Partial Migration Recovery for Password Reset Tokens

## 1. Problem
When migrating legacy or existing database schemas to the hardened `PasswordResetToken` schema, a database could exist in a partially migrated state (e.g., previous migration was interrupted after adding `code_hash`, but before adding `session_token_hash`, `code_expires_at`, `session_expires_at`, or `created_at`).
In PostgreSQL and MySQL, the previous migration checked only if `code_hash` existed; if so, it skipped adding the rest of the hardened columns, leading to runtime failures due to missing schema fields.

## 2. Goal
Ensure `HardenPasswordResetTokens` migration is strictly atomic per column, idempotent, and resilient against any intermediate, partial, or legacy schema state across PostgreSQL, MySQL, and SQLite.

## 3. Scope
### In Scope
- Independent column-existence detection and addition for all hardened columns:
  - `code_hash`
  - `session_token_hash`
  - `code_expires_at`
  - `session_expires_at`
  - `created_at`
- Independent index-existence detection and creation for all indexes:
  - `idx_password_reset_tokens_email`
  - `idx_password_reset_tokens_code_expires_at`
  - `idx_password_reset_tokens_session_hash`
- Complete removal of legacy plaintext columns (`code`, `sessionToken`, `codeExpiresAt`, `sessionExpiresAt`).
- Invalidation of legacy rows (`used = true`).
- Comprehensive multi-state tests covering:
  1. Original plaintext schema.
  2. Partially migrated schema with only `code_hash`.
  3. Partially migrated schema with arbitrary subset of columns.
  4. Fully hardened schema.
  5. Running the migration twice (idempotence).

### Out of Scope
- Altering the runtime password reset authentication logic (already verified and secure).

## 4. Actors
- Database Migrator (Fluent AsyncMigration runner / Application startup)
- Backend Application Server
- Database Engine (PostgreSQL, MySQL, SQLite)

## 5. Functional Requirements
- **FR-001**: Migration MUST inspect and add each hardened column independently if missing.
- **FR-002**: Migration MUST NOT skip subsequent columns if one or more hardened columns already exist.
- **FR-003**: Migration MUST drop legacy plaintext columns (`code`, `sessionToken`, `codeExpiresAt`, `sessionExpiresAt`) if present.
- **FR-004**: Migration MUST mark any unconsumed legacy rows as `used = true`.
- **FR-005**: Migration MUST verify and ensure all lookup and unique indexes exist without errors if already created.
- **FR-006**: Migration MUST be safely repeatable multiple times on the same database without error (idempotent).

## 6. Non-Functional Requirements
- **NFR-001**: Dialect compatibility across PostgreSQL (16+), MySQL (8+), and SQLite (3+).
- **NFR-002**: Execution performance: under 500ms per database migration run.
- **NFR-003**: Zero downtime risk: column additions are nullable without default locking constraints.

## 7. Business Rules
- **BR-001**: No plaintext credentials (reset OTPs or session tokens) may remain stored or accessible after migration.
- **BR-002**: Prior unexpired reset tokens issued under legacy plaintext format are invalidated immediately on migration to enforce secure re-issuance.

## 8. Validation Rules
- **VAL-001**: After migration, querying `password_reset_tokens` for `code` or `sessionToken` must fail at SQL level (column does not exist).
- **VAL-002**: After migration, `code_hash`, `session_token_hash`, `code_expires_at`, `session_expires_at`, and `created_at` must all exist in the schema.

## 9. API Contract
Not applicable (internal database migration and persistence level).

## 10. Database Requirements
- **Table**: `password_reset_tokens`
- **Required Columns**:
  - `id` (UUID / VARCHAR(255) PRIMARY KEY)
  - `email` (VARCHAR(255) NOT NULL)
  - `code_hash` (VARCHAR(255) NULL)
  - `session_token_hash` (VARCHAR(255) NULL)
  - `code_expires_at` (TIMESTAMP / DATETIME / TEXT NULL)
  - `session_expires_at` (TIMESTAMP / DATETIME / TEXT NULL)
  - `created_at` (TIMESTAMP / DATETIME / TEXT NULL)
  - `verified` (BOOLEAN / INTEGER NOT NULL DEFAULT FALSE)
  - `used` (BOOLEAN / INTEGER NOT NULL DEFAULT FALSE)
  - `attempts` (INTEGER NOT NULL DEFAULT 0)
- **Indexes**:
  - `idx_password_reset_tokens_email` on (`email`)
  - `idx_password_reset_tokens_code_expires_at` on (`code_expires_at`)
  - `idx_password_reset_tokens_session_hash` UNIQUE on (`session_token_hash`)

## 11. Security Requirements
- All legacy plaintext columns dropped.
- All pre-migration records marked used (`used = true`).

## 12. Concurrency Requirements
- DDL statements must be safe and idempotent.

## 13. Error Handling
- Safe DDL error handling: `IF NOT EXISTS` / pre-flight `information_schema` inspection avoids syntax or table-lock aborts.

## 14. Acceptance Criteria
- **AC-001**: Running migration on legacy table produces all 5 hardened columns and drops all 4 legacy columns.
- **AC-002**: Running migration on partially migrated table (e.g. only `code_hash`) adds the remaining 4 missing columns and creates all indexes.
- **AC-003**: Running migration on arbitrary partial subset adds only the missing columns without error.
- **AC-004**: Running migration twice on a fully hardened table succeeds with no error or schema alteration.

## 15. Test Scenarios
- **Unit/Integration Tests**:
  - `testMigrationFromLegacyPlaintextSchema`
  - `testMigrationFromPartiallyMigratedSchemaWithOnlyCodeHash`
  - `testMigrationFromArbitrarySubsetOfColumns`
  - `testMigrationIdempotenceRerunTwice`

## 16. Observability
- Migration start and completion logged via Fluent migrator.

## 17. Open Questions
- None.

## 18. Assumptions
- PostgreSQL 9.6+ supports `ADD COLUMN IF NOT EXISTS` natively.
- MySQL 8+ supports `information_schema.COLUMNS` inspection.
