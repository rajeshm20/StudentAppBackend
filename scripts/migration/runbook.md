# PostgreSQL Migration Runbook

This runbook outlines the steps to safely migrate the production `student_db` from MySQL 8.4 to PostgreSQL 16.

## Pre-Requisites
1. Ensure the PostgreSQL 16 database instance is provisioned and accessible.
2. Ensure you have `pgloader` and `psql` installed on the migration runner machine.
3. Obtain the source MySQL connection string and target PostgreSQL connection string.

## Phase 1: Preparation & Canonicalization (Zero Downtime)
1. Export a snapshot of the current MySQL production database to a staging environment.
2. Run the canonicalization script against the staging MySQL database to clean data anomalies (e.g., lowercase emails, trim whitespace) that would violate strict PostgreSQL unique constraints.
   ```bash
   mysql -h staging-mysql -u root -p student_db < 01-canonicalize.sql
   ```
3. Resolve any constraint violations or orphaned records flagged during this process.

## Phase 2: Schema Translation & Migration (Maintenance Window)
1. **Engage Maintenance Mode**: Configure the application or load balancer to return 503 Maintenance Mode.
2. Run the canonicalization script one last time on the *live* MySQL database to ensure data consistency immediately prior to export.
3. Run `pgloader` using the provided configuration file to extract, transform, and load data into PostgreSQL:
   ```bash
   pgloader pgloader.load
   ```

## Phase 3: Validation & Cutover
1. Run the automated verification script to compare row counts and structural integrity between MySQL and PostgreSQL.
   ```bash
   ./02-verification.sh
   ```
2. Verify that sequence counters in PostgreSQL are correctly aligned to the maximum `id` in each table (handled by pgloader).
3. **Application Cutover**: Deploy the application with `DB_DRIVER=postgres` and the new `DATABASE_HOST` / `DATABASE_PASSWORD`.
4. Monitor application logs and error rates. Disable Maintenance Mode.

## Rollback Procedure
If critical failures occur post-cutover:
1. Re-engage Maintenance Mode.
2. Revert application configuration back to `DB_DRIVER=mysql` and the MySQL host.
3. Run the rollback verification in CI (`swift test` with MySQL) to ensure compatibility.
4. Disable Maintenance Mode. Data written to PostgreSQL during the window will require manual backporting to MySQL.
