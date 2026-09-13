-- PostgreSQL enforces strict unique constraints.
-- MySQL often ignores trailing whitespace and is case-insensitive by default.
-- This script canonicalizes the source data in MySQL before migration.

-- 1. Trim trailing/leading whitespace and lowercase emails
UPDATE students
SET email = LOWER(TRIM(email))
WHERE email != LOWER(TRIM(email));

-- 2. Clean contact numbers (remove any whitespace if applicable)
UPDATE students
SET contactNumber = REPLACE(contactNumber, ' ', '')
WHERE contactNumber LIKE '% %';

-- 3. Trim names
UPDATE students
SET name = TRIM(name)
WHERE name != TRIM(name);

-- (Optional) Add conflict resolution queries here if duplicates are found
-- e.g., identifying duplicated emails that will fail in PG:
-- SELECT email, COUNT(*) FROM students GROUP BY email HAVING COUNT(*) > 1;
