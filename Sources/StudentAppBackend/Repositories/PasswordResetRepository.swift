import Fluent
import Foundation
import Vapor

protocol PasswordResetRepository: Sendable {
    func create(_ token: PasswordResetToken, on db: any Database) async throws
    func update(_ token: PasswordResetToken, on db: any Database) async throws
    func findLatestActiveCode(forEmail email: String, on db: any Database) async throws -> PasswordResetToken?
    func findVerifiedSession(forEmail email: String, sessionToken: String, on db: any Database) async throws -> PasswordResetToken?
}

struct DatabasePasswordResetRepository: PasswordResetRepository {
    init() {}

    func create(_ token: PasswordResetToken, on db: any Database) async throws {
        try await token.save(on: db)
    }

    func update(_ token: PasswordResetToken, on db: any Database) async throws {
        try await token.save(on: db)
    }

    func findLatestActiveCode(forEmail email: String, on db: any Database) async throws -> PasswordResetToken? {
        try await PasswordResetToken.query(on: db)
            .filter(\.$email == email)
            .filter(\.$used == false)
            .filter(\.$verified == false)
            .sort(\.$codeExpiresAt, .descending)
            .first()
    }

    func findVerifiedSession(forEmail email: String, sessionToken: String, on db: any Database) async throws -> PasswordResetToken? {
        try await PasswordResetToken.query(on: db)
            .filter(\.$email == email)
            .filter(\.$sessionToken == sessionToken)
            .filter(\.$verified == true)
            .filter(\.$used == false)
            .first()
    }
}
