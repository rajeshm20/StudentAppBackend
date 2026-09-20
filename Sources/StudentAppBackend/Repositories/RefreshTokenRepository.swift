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

struct DatabaseRefreshTokenRepository: RefreshTokenRepository {
    init() {}

    func find(byHash tokenHash: String, on db: any Database) async throws -> RefreshToken? {
        try await RefreshToken.query(on: db)
            .filter(\.$tokenHash == tokenHash)
            .first()
    }

    /// Atomically guards and consumes an active refresh token.
    /// In PostgreSQL/MySQL, this uses `SELECT ... FOR UPDATE` row-level locking via SQLKit.
    /// If the token is already revoked, it returns `.alreadyRevoked` to trigger family invalidation.
    func consumeIfActive(byHash tokenHash: String, on db: any Database) async throws -> RefreshTokenConsumeResult {
        if let sql = db as? any SQLDatabase {
            _ = try await sql.select()
                .column("id")
                .from(RefreshToken.schema)
                .where("token_hash", .equal, tokenHash)
                .for(.update)
                .all()
        }

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
