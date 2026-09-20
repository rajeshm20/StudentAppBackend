import Fluent
import Foundation
import Vapor

protocol RevokedTokenRepository: Sendable {
    func isRevoked(jti: String, on db: any Database) async throws -> Bool
    func revoke(jti: String, expiresAt: Date, on db: any Database) async throws
}

struct DatabaseRevokedTokenRepository: RevokedTokenRepository {
    init() {}

    func isRevoked(jti: String, on db: any Database) async throws -> Bool {
        try await RevokedToken.query(on: db)
            .filter(\.$jti == jti)
            .first() != nil
    }

    func revoke(jti: String, expiresAt: Date, on db: any Database) async throws {
        let revoked = RevokedToken(jti: jti, expiresAt: expiresAt)
        try await revoked.save(on: db)
    }
}
