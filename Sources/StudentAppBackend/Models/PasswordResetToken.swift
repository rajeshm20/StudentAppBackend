//
//  PasswordResetToken.swift
//  StudentAppBackend
//
//  Created by Rajesh Mani on 23/07/26.
//


import Fluent
import Vapor

final class PasswordResetToken: Model, Content, @unchecked Sendable {
    static let schema = "password_reset_tokens"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "email")
    var email: String

    @Field(key: "code")
    var code: String            // 6-digit code emailed to the user

    @Field(key: "sessionToken")
    var sessionToken: String?   // issued only after code is verified; used for the actual reset call

    @Field(key: "codeExpiresAt")
    var codeExpiresAt: Date

    @Field(key: "sessionExpiresAt")
    var sessionExpiresAt: Date?

    @Field(key: "verified")
    var verified: Bool

    @Field(key: "used")
    var used: Bool

    init() {}

    init(id: UUID? = nil, email: String, code: String, codeExpiresAt: Date) {
        self.id = id
        self.email = email
        self.code = code
        self.codeExpiresAt = codeExpiresAt
        self.verified = false
        self.used = false
    }
}

struct CreatePasswordResetToken: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("password_reset_tokens")
            .id()
            .field("email", .string, .required)
            .field("code", .string, .required)
            .field("sessionToken", .string)
            .unique(on: "sessionToken")
            .field("codeExpiresAt", .datetime, .required)
            .field("sessionExpiresAt", .datetime)
            .field("verified", .bool, .required, .sql(.default(false)))
            .field("used", .bool, .required, .sql(.default(false)))
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("password_reset_tokens").delete()
    }
}
