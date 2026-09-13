I need to migrate my Vapor 4 / Swift 6 backend (StudentAppBackend) from MySQL to
PostgreSQL for a production-quality deployment on Render.

Context:
- Uses Fluent ORM with FluentMySQLDriver currently
- GraphQL API via Graphiti, REST routes, Docker + GHCR deployment
- Has existing migrations for models including Student and related entities
- Uses environment-variable-based configuration (DATABASE_PASSWORD, etc.) in configure.swift
- Has an existing security fix in place requiring env vars with no hardcoded fallback

Do NOT execute changes yet. First, produce an Implementation Plan covering:

1. Package.swift changes: replace FluentMySQLDriver with FluentPostgresDriver
2. configure.swift changes: switch DatabaseConfigurationFactory to .postgres(...),
   reading host/port/username/password/database from environment variables, with
   the same "fail loudly if missing" pattern as the existing DATABASE_PASSWORD fix
   (no silent defaults)
3. Audit every existing Migration file for MySQL-specific SQL or Fluent
   MySQL-only field types (e.g. .sql(.mysql(...)) raw SQL, AUTO_INCREMENT
   assumptions, MySQL-specific column types) and flag exactly which files need
   changes
4. Check for any raw/custom SQL queries anywhere in the codebase (not just
   migrations) that use MySQL syntax and would break on Postgres
5. Identify differences in how MySQL vs Postgres handle case-sensitivity,
   string collation, and enum types, and flag any model that could behave
   differently after the switch
6. A rollback plan: how to revert to MySQL if something breaks post-deploy
   (e.g. keep the MySQL driver behind a feature flag, or a documented revert
   commit)
7. A test plan: which existing tests must pass against Postgres before this
   is considered done, and whether I need a docker-compose Postgres service
   for local/CI testing

After I approve the plan, implement it file by file, show me the diff for
each file before moving to the next, and run the full test suite against a
local Postgres container at the end. Flag any test that was previously
passing against MySQL but fails against Postgres — don't silently adjust
the test to make it pass.