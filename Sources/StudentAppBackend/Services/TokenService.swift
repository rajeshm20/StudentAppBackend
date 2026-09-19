// MARK: - TokenService.swift
// Centralized JWT signing, verification, revocation, and request-scoped auth context.
// All authentication flows go through this service.
// Do NOT duplicate JWT parsing logic in controllers or GraphQL resolvers.

import Crypto
import Fluent
import Foundation
import JWT
import JWTKit
import Vapor

protocol TokenServiceProtocol: Sendable {
    func generateTokenPair(for student: Student, on req: Request) async throws -> TokenPairResponse
    func rotateRefreshToken(rawToken: String, on req: Request) async throws -> TokenPairResponse
    func revokeRefreshToken(rawToken: String, on db: any Database) async throws
}

struct TokenService: TokenServiceProtocol {
    private let refreshTokenRepository: any RefreshTokenRepository
    private let studentRepository: any StudentRepository

    init(
        refreshTokenRepository: any RefreshTokenRepository = DatabaseRefreshTokenRepository(),
        studentRepository: any StudentRepository = DatabaseStudentRepository()
    ) {
        self.refreshTokenRepository = refreshTokenRepository
        self.studentRepository = studentRepository
    }

    static let shared = TokenService()

    // MARK: - Token Pair Generation

    func generateTokenPair(for student: Student, on req: Request) async throws -> TokenPairResponse {
        let studentID = try student.requireID()
        let expirationDelta = AppConfig.jwtAccessTTL()
        let payload = StudentToken(
            exp: ExpirationClaim(value: Date(timeIntervalSinceNow: expirationDelta)),
            jti: IDClaim(value: UUID().uuidString),
            studentID: studentID,
            role: student.role
        )
        let accessToken = try req.jwt.sign(payload)

        // Cryptographically secure random Refresh Token (32 bytes / 256 bits hex)
        let rawRefreshToken = [UInt8].random(count: 32).hex
        let tokenHash = Self.hashToken(rawRefreshToken)

        // Persist hashed refresh token (valid for 30 days)
        let refreshTokenModel = RefreshToken(
            tokenHash: tokenHash,
            userID: studentID,
            expiresAt: Date().addingTimeInterval(30 * 86400),
            isRevoked: false
        )
        try await refreshTokenRepository.create(refreshTokenModel, on: req.db)

        return TokenPairResponse(
            accessToken: accessToken,
            refreshToken: rawRefreshToken,
            tokenType: "Bearer",
            expiresIn: Int(expirationDelta)
        )
    }

    // MARK: - Refresh Token Rotation & Reuse Detection

    func rotateRefreshToken(rawToken: String, on req: Request) async throws -> TokenPairResponse {
        let tokenHash = Self.hashToken(rawToken)

        // 1. Locate token by hash
        guard let existingToken = try await refreshTokenRepository.find(byHash: tokenHash, on: req.db) else {
            throw Abort(.unauthorized, reason: "Invalid refresh token.")
        }

        // 2. Reuse Detection: If an already revoked token is used, suspect token theft
        if existingToken.isRevoked {
            // Invalidate ALL sessions/tokens for this user immediately
            try await refreshTokenRepository.revokeAll(forUserID: existingToken.$user.id, on: req.db)

            req.logger.critical("Compromised token reuse detected for user ID: \(existingToken.$user.id). Revoked all sessions.")
            throw Abort(.unauthorized, reason: "Invalid authentication state. Please log in again.")
        }

        // 3. Check expiration
        guard existingToken.expiresAt > Date() else {
            existingToken.isRevoked = true
            try await refreshTokenRepository.update(existingToken, on: req.db)
            throw Abort(.unauthorized, reason: "Refresh token has expired.")
        }

        // 4. Invalidate used token
        existingToken.isRevoked = true
        try await refreshTokenRepository.update(existingToken, on: req.db)

        // 5. Fetch associated student
        guard let student = try await studentRepository.find(byID: existingToken.$user.id, on: req.db) else {
            throw Abort(.unauthorized, reason: "Invalid authentication state. User not found.")
        }

        guard student.status.isLoginPermitted else {
            throw Abort(.unauthorized, reason: "Account is suspended or inactive.")
        }

        // 6. Issue fresh token pair
        return try await generateTokenPair(for: student, on: req)
    }

    // MARK: - Refresh Token Revocation

    func revokeRefreshToken(rawToken: String, on db: any Database) async throws {
        let tokenHash = Self.hashToken(rawToken)
        try await refreshTokenRepository.revoke(byHash: tokenHash, on: db)
    }

    static func hashToken(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Legacy / Direct Helper Methods

    /// Signs a JWT access token for the given student/user.
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

    /// Resolves the authenticated student from the current request.
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

        request.authenticatedStudent = student
        request.authenticatedToken = payload
        request.authenticatedRole = payload.role

        return student
    }

    /// Revokes an access token's JTI.
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

private extension Array where Element == UInt8 {
    var hex: String {
        self.map { String(format: "%02hhx", $0) }.joined()
    }
}
