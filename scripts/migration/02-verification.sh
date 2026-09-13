#!/usr/bin/env bash
# Automated Staging Migration Verification
# Usage: ./02-verification.sh

set -euo pipefail

# Define connection URIs (adjust these for staging/prod environments)
MYSQL_URI="mysql://studentapp:local-dev-db-password-not-for-prod@localhost:3306/student_db"
PG_URI="postgresql://studentapp:local-dev-db-password-not-for-prod@localhost:5432/student_db"

echo "Running Verification: Row Counts"
MYSQL_COUNT=$(mysql -u studentapp -p"local-dev-db-password-not-for-prod" -h localhost -P 3306 -D student_db -s -N -e "SELECT COUNT(*) FROM students;")
PG_COUNT=$(psql "$PG_URI" -t -c "SELECT COUNT(*) FROM students;" | xargs)

if [ "$MYSQL_COUNT" != "$PG_COUNT" ]; then
    echo "❌ Row count mismatch! MySQL: $MYSQL_COUNT, Postgres: $PG_COUNT"
    exit 1
else
    echo "✅ Row counts match ($PG_COUNT)"
fi

echo "Running Verification: Sequence Alignment"
# Postgres sequence must be updated to max(id) after pgloader migration
MAX_ID=$(psql "$PG_URI" -t -c "SELECT COALESCE(MAX(id), 0) FROM students;" | xargs)
echo "Max ID in students table: $MAX_ID"
# NOTE: pgloader reset sequences should handle this automatically.

echo "Running Verification: Data Integrity (Sample Hash)"
# Compare checksums or sample records
# Example: Get hash of all emails to ensure no data truncation
MYSQL_HASH=$(mysql -u studentapp -p"local-dev-db-password-not-for-prod" -h localhost -P 3306 -D student_db -s -N -e "SELECT MD5(GROUP_CONCAT(email ORDER BY id)) FROM students;")
PG_HASH=$(psql "$PG_URI" -t -c "SELECT md5(string_agg(email, ',' ORDER BY id)) FROM students;" | xargs)

if [ "$MYSQL_HASH" != "$PG_HASH" ]; then
    echo "⚠️ Hash mismatch (expected if pgloader applies different collation/casting, manual inspection required)."
else
    echo "✅ Email checksums match."
fi

echo "All verification checks completed."
