//
//  PasswordResetToken.swift
//  StudentAppBackend
//
//  Created by Rajesh Mani on 23/07/26.
//

import Fluent
import SQLKit
import Vapor

final class PasswordResetToken: Model, Content, @unchecked Sendable {
    static let schema = "password_reset_tokens"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "email")
    var email: String

    @Field(key: "code_hash")
    var codeHash: String        // HMAC-SHA256 hash of the 6-digit OTP

    @Field(key: "session_token_hash")
    var sessionTokenHash: String?   // SHA-256 hash of the post-verification session token

    @Field(key: "code_expires_at")
    var codeExpiresAt: Date

    @Field(key: "session_expires_at")
    var sessionExpiresAt: Date?

    @Field(key: "verified")
    var verified: Bool

    @Field(key: "used")
    var used: Bool

    @Field(key: "attempts")
    var attempts: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        email: String,
        codeHash: String,
        codeExpiresAt: Date
    ) {
        self.id = id
        self.email = email
        self.codeHash = codeHash
        self.codeExpiresAt = codeExpiresAt
        self.verified = false
        self.used = false
        self.attempts = 0
    }
}

struct CreatePasswordResetToken: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("password_reset_tokens")
            .id()
            .field("email", .string, .required)
            .field("code_hash", .string, .required)
            .field("session_token_hash", .string)
            .unique(on: "session_token_hash")
            .field("code_expires_at", .datetime, .required)
            .field("session_expires_at", .datetime)
            .field("verified", .bool, .required, .sql(.default(false)))
            .field("used", .bool, .required, .sql(.default(false)))
            .field("attempts", .int, .required, .sql(.default(0)))
            .field("created_at", .datetime)
            .create()

        if let sql = database as? any SQLDatabase {
            let dialect = sql.dialect.name.lowercased()
            let driverName = "\(type(of: database))".lowercased()
            let isPostgres = dialect.contains("postgres") || dialect.contains("psql") || driverName.contains("postgres") || driverName.contains("psql")
            let isSQLite = dialect.contains("sqlite") || driverName.contains("sqlite")
            let isMySQL = dialect.contains("mysql") || driverName.contains("mysql")

            if isPostgres || isSQLite {
                try await sql.raw("""
                    CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_email
                    ON password_reset_tokens (email)
                """).run()
                try await sql.raw("""
                    CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_code_expires_at
                    ON password_reset_tokens (code_expires_at)
                """).run()
            } else if isMySQL {
                try await sql.raw("""
                    ALTER TABLE password_reset_tokens
                    ADD INDEX idx_password_reset_tokens_email (`email`)
                """).run()
                try await sql.raw("""
                    ALTER TABLE password_reset_tokens
                    ADD INDEX idx_password_reset_tokens_code_expires_at (`code_expires_at`)
                """).run()
            }
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("password_reset_tokens").delete()
    }
}
