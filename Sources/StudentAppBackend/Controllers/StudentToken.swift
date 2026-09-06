// MARK: - StudentToken.swift
// JWT payload for all user roles (Admin, Principal, Teacher, Student).
// The `role` claim allows middleware to perform role checks without a DB round-trip.
// NEVER include: password, passwordHash, confirmPassword, or sensitive personal data.

@preconcurrency import JWTKit
import Foundation

struct StudentToken: JWTPayload, Sendable {
    // MARK: - Standard Claims

    /// Expiration time claim — automatically verified by JWTKit.
    var exp: ExpirationClaim

    /// Unique token ID — used for revocation checks.
    var jti: IDClaim

    // MARK: - Application Claims

    /// The authenticated user's database ID.
    var studentID: UUID

    /// The authenticated user's role — assigned server-side, never from client input.
    /// Used by RoleMiddleware to enforce access control without a DB round-trip.
    var role: UserRole

    // MARK: - Verification

    func verify(using signer: JWTSigner) throws {
        try self.exp.verifyNotExpired()
    }
}
