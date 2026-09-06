// MARK: - TokenService.swift
// Centralized JWT signing, verification, revocation, and request-scoped auth context.
// All authentication flows go through this service.
// Do NOT duplicate JWT parsing logic in controllers or GraphQL resolvers.

import Fluent
import JWTKit
import JWT
import Vapor

enum TokenService {
    // MARK: - Token Signing

    /// Signs a JWT access token for the given student/user.
    /// The `role` is embedded from the server-side record — never from client input.
    static func signAccessToken(for student: Student, on request: Request) throws -> String {
        let expiration = ExpirationClaim(value: Date(timeIntervalSinceNow: AppConfig.jwtAccessTTL()))
        let payload = StudentToken(
            exp: expiration,
            jti: IDClaim(value: UUID().uuidString),
            studentID: try student.requireID(),
            role: student.role
        )
        return try request.jwt.sign(payload)
    }

    // MARK: - Token Verification

    /// Verifies a JWT bearer token and checks it has not been revoked.
    static func verifyAccessToken(_ token: String, on request: Request) async throws -> StudentToken {
        let payload = try request.jwt.verify(token, as: StudentToken.self)

        if try await RevokedToken.query(on: request.db)
            .filter(\.$jti == payload.jti.value)
            .first() != nil {
            throw Abort(.unauthorized, reason: "Token revoked")
        }

        return payload
    }

    // MARK: - Request Authentication Context

    /// Resolves the authenticated student from the current request.
    /// Uses cached storage to avoid repeated DB lookups within the same request lifecycle.
    ///
    /// - Important: This also populates `request.authenticatedRole` from the JWT claim,
    ///   so role checks do NOT require an extra DB round-trip.
    static func authenticateStudent(from request: Request) async throws -> Student {
        if let student = request.authenticatedStudent {
            return student
        }

        guard let bearer = request.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Missing or invalid Authorization header")
        }

        let payload = try await verifyAccessToken(bearer.token, on: request)

        guard let student = try await Student.find(payload.studentID, on: request.db) else {
            throw Abort(.unauthorized, reason: "Invalid token")
        }

        // Cache in request storage for the duration of this request
        request.authenticatedStudent = student
        request.authenticatedToken = payload
        request.authenticatedRole = payload.role

        return student
    }

    // MARK: - Token Revocation

    static func revokeToken(_ payload: StudentToken, on database: any Database) async throws {
        let revokedToken = RevokedToken(jti: payload.jti.value, expiresAt: payload.exp.value)
        try await revokedToken.save(on: database)
    }
}

// MARK: - Request Storage Keys

extension Request {
    struct AuthenticatedStudentKey: StorageKey {
        typealias Value = Student
    }

    struct AuthenticatedTokenKey: StorageKey {
        typealias Value = StudentToken
    }

    struct AuthenticatedRoleKey: StorageKey {
        typealias Value = UserRole
    }

    /// The authenticated student for this request. Set by `TokenService.authenticateStudent(from:)`.
    var authenticatedStudent: Student? {
        get { storage[AuthenticatedStudentKey.self] }
        set { storage[AuthenticatedStudentKey.self] = newValue }
    }

    /// The verified JWT payload for this request.
    var authenticatedToken: StudentToken? {
        get { storage[AuthenticatedTokenKey.self] }
        set { storage[AuthenticatedTokenKey.self] = newValue }
    }

    /// The authenticated user's role — sourced from the JWT claim (no DB round-trip required).
    /// Available after `JWTAuthMiddleware` or `TokenService.authenticateStudent(from:)` runs.
    var authenticatedRole: UserRole? {
        get { storage[AuthenticatedRoleKey.self] }
        set { storage[AuthenticatedRoleKey.self] = newValue }
    }
}
