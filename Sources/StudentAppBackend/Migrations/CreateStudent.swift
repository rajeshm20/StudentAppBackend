//
//  CreateStudent.swift
//  StudentAppBackend
//
//  Created by Rajesh Mani on 07/08/25.
//


// MARK: - CreateStudent.swift
import Fluent

struct CreateStudent: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("students")
            .id()
            .field("name", .string, .required)
            .field("email", .string, .required)
            .unique(on: "email")
            .field("passwordHash", .string, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("students").delete()
    }
}
