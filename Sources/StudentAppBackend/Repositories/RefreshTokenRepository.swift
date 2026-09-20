import Fluent
import Foundation
import SQLKit
import Vapor

enum RefreshTokenConsumeResult: Sendable {
    case consumed(RefreshToken)
    case alreadyRevoked(userID: UUID)
    case expired(RefreshToken)
    case notFound
}

protocol RefreshTokenRepository: Sendable {
    func find(byHash tokenHash: String, on db: any Database) async throws -> RefreshToken?
    func consumeIfActive(byHash tokenHash: String, on db: any Database) async throws -> RefreshTokenConsumeResult
    func create(_ token: RefreshToken, on db: any Database) async throws
    func update(_ token: RefreshToken, on db: any Database) async throws
    func revokeAll(forUserID userID: UUID, on db: any Database) async throws
    func revoke(byHash tokenHash: String, on db: any Database) async throws
    func deleteExpiredOrRevoked(before date: Date, on db: any Database) async throws -> Int
}

struct RefreshTokenRow: Decodable, Sendable {
    let id: UUID
    let userID: UUID
    let expiresAt: Date
    let isRevoked: Bool

    init(id: UUID, userID: UUID, expiresAt: Date, isRevoked: Bool) {
        self.id = id
        self.userID = userID
        self.expiresAt = expiresAt
        self.isRevoked = isRevoked
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)

        // ID decoding (UUID or String)
        if let uuid = try? container.decode(UUID.self, forKeys: ["id", "ID"]) {
            self.id = uuid
        } else if let str = try? container.decode(String.self, forKeys: ["id", "ID"]), let uuid = UUID(uuidString: str) {
            self.id = uuid
        } else {
            self.id = try container.decode(UUID.self, forKeys: ["id", "ID"])
        }

        // User ID decoding (UUID or String)
        if let uuid = try? container.decode(UUID.self, forKeys: ["userid", "userID", "user_id", "USER_ID"]) {
            self.userID = uuid
        } else if let str = try? container.decode(String.self, forKeys: ["userid", "userID", "user_id", "USER_ID"]), let uuid = UUID(uuidString: str) {
            self.userID = uuid
        } else {
            self.userID = try container.decode(UUID.self, forKeys: ["userid", "userID", "user_id", "USER_ID"])
        }

        // Expiration Date decoding (Date, Double timestamp, or ISO8601 String)
        if let date = try? container.decode(Date.self, forKeys: ["expiresat", "expiresAt", "expires_at", "EXPIRES_AT"]) {
            self.expiresAt = date
        } else if let timestamp = try? container.decode(Double.self, forKeys: ["expiresat", "expiresAt", "expires_at", "EXPIRES_AT"]) {
            self.expiresAt = Date(timeIntervalSince1970: timestamp)
        } else if let dateStr = try? container.decode(String.self, forKeys: ["expiresat", "expiresAt", "expires_at", "EXPIRES_AT"]) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr) {
                self.expiresAt = date
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Invalid ISO-8601 date string for token expiration: '\(dateStr)'"
                    )
                )
            }
        } else {
            self.expiresAt = try container.decode(Date.self, forKeys: ["expiresat", "expiresAt", "expires_at", "EXPIRES_AT"])
        }

        // Revocation state decoding (Bool or 0/1 Integer)
        if let boolVal = try? container.decode(Bool.self, forKeys: ["isrevoked", "isRevoked", "is_revoked", "IS_REVOKED"]) {
            self.isRevoked = boolVal
        } else if let intVal = try? container.decode(Int.self, forKeys: ["isrevoked", "isRevoked", "is_revoked", "IS_REVOKED"]) {
            self.isRevoked = (intVal != 0)
        } else {
            self.isRevoked = try container.decode(Bool.self, forKeys: ["isrevoked", "isRevoked", "is_revoked", "IS_REVOKED"])
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer where K == DynamicCodingKey {
    func decode<T: Decodable>(_ type: T.Type, forKeys keys: [String]) throws -> T {
        for key in keys {
            if let codingKey = DynamicCodingKey(stringValue: key),
               let value = try? self.decode(T.self, forKey: codingKey) {
                return value
            }
        }
        let fallbackKey = DynamicCodingKey(stringValue: keys[0])!
        return try self.decode(T.self, forKey: fallbackKey)
    }
}

struct DatabaseRefreshTokenRepository: RefreshTokenRepository {
    init() {}

    func find(byHash tokenHash: String, on db: any Database) async throws -> RefreshToken? {
        try await RefreshToken.query(on: db)
            .filter(\.$tokenHash == tokenHash)
            .first()
    }

    /// Atomically consumes an active refresh token in a single database statement.
    ///
    /// Recommended Enterprise Pattern:
    /// 1. Execute an atomic UPDATE that only updates rows matching:
    ///    - token_hash == tokenHash
    ///    - is_revoked == false
    ///    - expires_at > now
    ///    and returns the row via RETURNING.
    ///    Only ONE concurrent request can ever win this UPDATE.
    ///
    /// 2. If 0 rows were updated, execute a follow-up SELECT to distinguish:
    ///    - Token not found -> `.notFound`
    ///    - Token already revoked -> `.alreadyRevoked(userID:)` (triggers reuse detection)
    ///    - Token expired -> `.expired(token)`
    func consumeIfActive(byHash tokenHash: String, on db: any Database) async throws -> RefreshTokenConsumeResult {
        guard let sql = db as? any SQLDatabase else {
            // Fallback for non-SQL drivers
            guard let token = try await find(byHash: tokenHash, on: db) else {
                return .notFound
            }
            guard !token.isRevoked else {
                return .alreadyRevoked(userID: token.$user.id)
            }
            if token.expiresAt <= Date() {
                token.isRevoked = true
                try await update(token, on: db)
                return .expired(token)
            }
            token.isRevoked = true
            try await update(token, on: db)
            return .consumed(token)
        }

        let now = Date()
        let isMySQL = sql.dialect.name.lowercased().contains("mysql")

        if isMySQL {
            // MySQL fallback (MySQL lacks UPDATE ... RETURNING support)
            // Acquire row lock with SELECT ... FOR UPDATE, then conditional update
            _ = try await sql.select()
                .column("id")
                .from(RefreshToken.schema)
                .where("token_hash", .equal, tokenHash)
                .for(.update)
                .all()

            guard let token = try await find(byHash: tokenHash, on: db) else {
                return .notFound
            }
            guard !token.isRevoked else {
                return .alreadyRevoked(userID: token.$user.id)
            }
            if token.expiresAt <= now {
                token.isRevoked = true
                try await update(token, on: db)
                return .expired(token)
            }
            token.isRevoked = true
            try await update(token, on: db)
            return .consumed(token)
        }

        // PostgreSQL & SQLite: Atomic UPDATE-first in one statement with RETURNING
        let updatedRow: RefreshTokenRow? = try await sql.raw("""
            UPDATE refresh_tokens
            SET is_revoked = true
            WHERE token_hash = \(bind: tokenHash)
              AND is_revoked = false
              AND expires_at > \(bind: now)
            RETURNING id, user_id, expires_at, is_revoked
        """).first(decoding: RefreshTokenRow.self)

        if let row = updatedRow {
            return .consumed(
                RefreshToken(
                    id: row.id,
                    tokenHash: tokenHash,
                    userID: row.userID,
                    expiresAt: row.expiresAt,
                    isRevoked: true
                )
            )
        }

        // Zero rows updated: Distinguish not found, already revoked (replay), or expired
        let existingRow: RefreshTokenRow? = try await sql.raw("""
            SELECT id, user_id, expires_at, is_revoked
            FROM refresh_tokens
            WHERE token_hash = \(bind: tokenHash)
        """).first(decoding: RefreshTokenRow.self)

        guard let existing = existingRow else {
            return .notFound
        }

        if existing.isRevoked {
            return .alreadyRevoked(userID: existing.userID)
        }

        if existing.expiresAt <= now {
            try await sql.raw("""
                UPDATE refresh_tokens
                SET is_revoked = true
                WHERE token_hash = \(bind: tokenHash)
                  AND is_revoked = false
            """).run()

            return .expired(
                RefreshToken(
                    id: existing.id,
                    tokenHash: tokenHash,
                    userID: existing.userID,
                    expiresAt: existing.expiresAt,
                    isRevoked: true
                )
            )
        }

        return .notFound
    }

    func create(_ token: RefreshToken, on db: any Database) async throws {
        try await token.save(on: db)
    }

    func update(_ token: RefreshToken, on db: any Database) async throws {
        try await token.save(on: db)
    }

    func revokeAll(forUserID userID: UUID, on db: any Database) async throws {
        try await RefreshToken.query(on: db)
            .filter(\.$user.$id == userID)
            .set(\.$isRevoked, to: true)
            .update()
    }

    func revoke(byHash tokenHash: String, on db: any Database) async throws {
        if let token = try await find(byHash: tokenHash, on: db) {
            token.isRevoked = true
            try await token.save(on: db)
        }
    }

    func deleteExpiredOrRevoked(before date: Date = Date(), on db: any Database) async throws -> Int {
        let tokens = try await RefreshToken.query(on: db)
            .group(.or) { group in
                group.filter(\.$expiresAt < date)
                group.filter(\.$isRevoked == true)
            }
            .all()
        let count = tokens.count
        for token in tokens {
            try await token.delete(on: db)
        }
        return count
    }
}
