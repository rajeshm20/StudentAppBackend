import Fluent
import Foundation
import SQLKit
import Vapor

protocol PasswordResetRepository: Sendable {
    func create(_ token: PasswordResetToken, on db: any Database) async throws
    func update(_ token: PasswordResetToken, on db: any Database) async throws
    func invalidateAll(forEmail email: String, on db: any Database) async throws
    func findLatestActiveCode(forEmail email: String, on db: any Database) async throws -> PasswordResetToken?
    func findVerifiedSession(forEmail email: String, sessionTokenHash: String, on db: any Database) async throws -> PasswordResetToken?
    func consumeSessionIfActive(sessionTokenHash: String, email: String, on db: any Database) async throws -> Bool
    func cleanupExpiredOrUsed(before date: Date, on db: any Database) async throws -> Int
}

struct DatabasePasswordResetRepository: PasswordResetRepository {
    init() {}

    func create(_ token: PasswordResetToken, on db: any Database) async throws {
        try await token.save(on: db)
    }

    func update(_ token: PasswordResetToken, on db: any Database) async throws {
        try await token.save(on: db)
    }

    func invalidateAll(forEmail email: String, on db: any Database) async throws {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        try await PasswordResetToken.query(on: db)
            .filter(\.$email == normalizedEmail)
            .filter(\.$used == false)
            .set(\.$used, to: true)
            .update()
    }

    func findLatestActiveCode(forEmail email: String, on db: any Database) async throws -> PasswordResetToken? {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        return try await PasswordResetToken.query(on: db)
            .filter(\.$email == normalizedEmail)
            .filter(\.$used == false)
            .filter(\.$verified == false)
            .sort(\.$codeExpiresAt, .descending)
            .first()
    }

    func findVerifiedSession(forEmail email: String, sessionTokenHash: String, on db: any Database) async throws -> PasswordResetToken? {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        return try await PasswordResetToken.query(on: db)
            .filter(\.$email == normalizedEmail)
            .filter(\.$sessionTokenHash == sessionTokenHash)
            .filter(\.$verified == true)
            .filter(\.$used == false)
            .first()
    }

    func consumeSessionIfActive(sessionTokenHash: String, email: String, on db: any Database) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "PasswordResetRepository requires an SQLDatabase-compatible driver for atomic session consumption.")
        }

        let dialect = sql.dialect.name.lowercased()
        let driverName = "\(type(of: db))".lowercased()
        let isPostgres = dialect.contains("postgres") || dialect.contains("psql") || driverName.contains("postgres") || driverName.contains("psql")
        let isSQLite = dialect.contains("sqlite") || driverName.contains("sqlite")
        let isMySQL = dialect.contains("mysql") || driverName.contains("mysql")
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        let now = Date()

        if isPostgres || isSQLite {
            struct ConsumedRow: Decodable {
                let id: String
            }
            let rows = try await sql.raw("""
                UPDATE password_reset_tokens
                SET used = true
                WHERE session_token_hash = \(bind: sessionTokenHash)
                  AND email = \(bind: normalizedEmail)
                  AND verified = true
                  AND used = false
                  AND session_expires_at > \(bind: now)
                RETURNING id
            """).all(decoding: ConsumedRow.self)

            return !rows.isEmpty
        } else if isMySQL {
            struct MySQLResetRow: Decodable {
                let id: String
            }
            // Acquire row-level exclusive lock within enclosing transaction
            let rows = try await sql.raw("""
                SELECT id
                FROM password_reset_tokens
                WHERE session_token_hash = \(bind: sessionTokenHash)
                  AND email = \(bind: normalizedEmail)
                  AND verified = true
                  AND used = false
                  AND session_expires_at > \(bind: now)
                FOR UPDATE
            """).all(decoding: MySQLResetRow.self)

            guard let first = rows.first else {
                return false
            }

            try await sql.raw("""
                UPDATE password_reset_tokens
                SET used = true
                WHERE id = \(bind: first.id)
            """).run()

            return true
        } else {
            throw Abort(.internalServerError, reason: "Unsupported SQL dialect for atomic reset session consumption.")
        }
    }

    func cleanupExpiredOrUsed(before date: Date, on db: any Database) async throws -> Int {
        let staleTokens = try await PasswordResetToken.query(on: db)
            .group(.or) { group in
                group.filter(\.$used == true)
                group.group(.and) { andGroup in
                    andGroup.filter(\.$codeExpiresAt < date)
                    andGroup.filter(\.$verified == false)
                }
                group.group(.and) { andGroup in
                    andGroup.filter(\.$sessionExpiresAt != nil)
                    andGroup.filter(\.$sessionExpiresAt < date)
                }
            }
            .all()

        let count = staleTokens.count
        try await staleTokens.delete(on: db)
        return count
    }
}
