// MARK: - AddRoleStatusPhoneToStudents.swift
// Additive migration — never drops existing columns.
// Existing rows receive safe defaults: role=student, status=active.
// New columns: role, status, firstName, lastName, countryCode, contactNumber, createdAt, updatedAt.
//
// SQLite compatibility:
//   - SQLite's ALTER TABLE only supports ONE column addition per statement.
//   - We issue one schema().update() call per column (Fluent wraps each in ALTER TABLE ADD COLUMN).
//   - MySQL supports multiple columns per ALTER TABLE but we use the same single-column approach
//     for portability.

import Fluent
import SQLKit

struct AddRoleStatusPhoneToStudents: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Issue ONE ALTER TABLE ADD COLUMN per schema update (SQLite compatibility)
        try await database.schema("students").field("role", .string).update()
        try await database.schema("students").field("status", .string).update()
        try await database.schema("students").field("firstName", .string).update()
        try await database.schema("students").field("lastName", .string).update()
        try await database.schema("students").field("countryCode", .string).update()
        // contactNumber stores normalized E.164 value, e.g. "+919876543210"
        try await database.schema("students").field("contactNumber", .string).update()
        try await database.schema("students").field("createdAt", .datetime).update()
        try await database.schema("students").field("updatedAt", .datetime).update()

        // Backfill safe defaults for all existing rows
        if let sql = database as? any SQLDatabase {
            try await sql.raw("UPDATE students SET role = 'student' WHERE role IS NULL").run()
            try await sql.raw("UPDATE students SET status = 'active' WHERE status IS NULL").run()

            // Add UNIQUE index on contactNumber for MySQL only
            // (SQLite does not support NULL-aware partial UNIQUE indexes via simple syntax)
            let driverName = "\(type(of: database))"
            if driverName.lowercased().contains("mysql") {
                try? await sql.raw("""
                    ALTER TABLE students
                    ADD UNIQUE INDEX students_contactNumber_unique (contactNumber)
                """).run()
            }
            // SQLite: application-layer duplicate check in StudentService handles uniqueness
        }
    }

    func revert(on database: any Database) async throws {
        // Drop the UNIQUE index first (MySQL only)
        if let sql = database as? any SQLDatabase {
            let driverName = "\(type(of: database))"
            if driverName.lowercased().contains("mysql") {
                try? await sql.raw("""
                    ALTER TABLE students DROP INDEX students_contactNumber_unique
                """).run()
            }
        }

        // Remove each added column with separate ALTER TABLE statements (SQLite compatibility)
        try await database.schema("students").deleteField("updatedAt").update()
        try await database.schema("students").deleteField("createdAt").update()
        try await database.schema("students").deleteField("contactNumber").update()
        try await database.schema("students").deleteField("countryCode").update()
        try await database.schema("students").deleteField("lastName").update()
        try await database.schema("students").deleteField("firstName").update()
        try await database.schema("students").deleteField("status").update()
        try await database.schema("students").deleteField("role").update()
    }
}
