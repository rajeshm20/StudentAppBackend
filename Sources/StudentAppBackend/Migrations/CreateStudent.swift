//
//  CreateStudent.swift
//  StudentAppBackend
//
//  Created by Rajesh Mani on 07/08/25.
//


// MARK: - CreateStudent.swift
import Fluent
import FluentSQL

struct CreateStudent: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("students")
            .id()
            .field("name", .string, .required, .sql(.check(SQLRaw("CHAR_LENGTH(name) <= 100"))))
            .field("email", .string, .required, .sql(.check(SQLRaw("CHAR_LENGTH(email) <= 254"))))
            .unique(on: "email")
            .field("passwordHash", .string, .required)
            .field("dob", .date)
            .field("phoneNumber", .string, .sql(.check(SQLRaw("phoneNumber IS NULL OR (CHAR_LENGTH(phoneNumber) >= 10 AND CHAR_LENGTH(phoneNumber) <= 20)"))))
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("students").delete()
    }
}
