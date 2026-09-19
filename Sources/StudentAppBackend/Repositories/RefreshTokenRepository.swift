import Fluent
import Foundation
import Vapor

protocol RefreshTokenRepository: Sendable {
    func find(byHash tokenHash: String, on db: any Database) async throws -> RefreshToken?
    func create(_ token: RefreshToken, on db: any Database) async throws
    func update(_ token: RefreshToken, on db: any Database) async throws
    func revokeAll(forUserID userID: UUID, on db: any Database) async throws
    func revoke(byHash tokenHash: String, on db: any Database) async throws
}

struct DatabaseRefreshTokenRepository: RefreshTokenRepository {
    init() {}

    func find(byHash tokenHash: String, on db: any Database) async throws -> RefreshToken? {
        try await RefreshToken.query(on: db)
            .filter(\.$tokenHash == tokenHash)
            .first()
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
}
