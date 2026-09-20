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
    func generateTokenPair(for student: Student, on req: Request, db: any Database) async throws -> TokenPairResponse
    func rotateRefreshToken(rawToken: String, on req: Request) async throws -> TokenPairResponse
    func revokeRefreshToken(rawToken: String, on db: any Database) async throws
    func revokeAllSessions(for studentID: UUID, on db: any Database) async throws
    func cleanupExpiredTokens(on db: any Database) async throws -> Int
}

struct TokenService: TokenServiceProtocol {
    private let refreshTokenRepository: any RefreshTokenRepository
    private let studentRepository: any StudentRepository
    private let revokedTokenRepository: any RevokedTokenRepository

    init(
        refreshTokenRepository: any RefreshTokenRepository = DatabaseRefreshTokenRepository(),
        studentRepository: any StudentRepository = DatabaseStudentRepository(),
        revokedTokenRepository: any RevokedTokenRepository = DatabaseRevokedTokenRepository()
    ) {
        self.refreshTokenRepository = refreshTokenRepository
        self.studentRepository = studentRepository
        self.revokedTokenRepository = revokedTokenRepository
    }

    static let shared = TokenService()

    // MARK: - Token Pair Generation

    func generateTokenPair(for student: Student, on req: Request) async throws -> TokenPairResponse {
        try await generateTokenPair(for: student, on: req, db: req.db)
    }

    func generateTokenPair(for student: Student, on req: Request, db: any Database) async throws -> TokenPairResponse {
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

        // Persist hashed refresh token using configured TTL (defaults to 7 days)
        let refreshTTL = AppConfig.jwtRefreshTTL()
        let refreshTokenModel = RefreshToken(
            tokenHash: tokenHash,
            userID: studentID,
            expiresAt: Date().addingTimeInterval(refreshTTL),
            isRevoked: false
        )
        try await refreshTokenRepository.create(refreshTokenModel, on: db)

        return TokenPairResponse(
            accessToken: accessToken,
            refreshToken: rawRefreshToken,
            tokenType: "Bearer",
            expiresIn: Int(expirationDelta)
        )
    }

    // MARK: - Refresh Token Rotation & Reuse Detection

    private enum RotationOutcome {
        case issued(TokenPairResponse)
        case notFound
        case reuseDetected(userID: UUID)
        case expired
    }

    func rotateRefreshToken(rawToken: String, on req: Request) async throws -> TokenPairResponse {
        let tokenHash = Self.hashToken(rawToken)

        do {
            let outcome = try await req.db.transaction { db -> RotationOutcome in
                // 1. Atomically check and consume token with row-level lock (FOR UPDATE / UPDATE ... RETURNING)
                let consumeResult = try await refreshTokenRepository.consumeIfActive(byHash: tokenHash, on: db)

                switch consumeResult {
                case .notFound:
                    return .notFound

                case .alreadyRevoked(let userID):
                    // Atomically revoke all user sessions within the same transaction and commit
                    try await refreshTokenRepository.revokeAll(forUserID: userID, on: db)
                    return .reuseDetected(userID: userID)

                case .expired:
                    // consumeIfActive already marked this expired token as revoked in the database;
                    // committing the transaction guarantees this lifecycle state transition persists.
                    return .expired

                case .consumed(let existingToken):
                    // 2. Fetch associated student via repository abstraction
                    guard let student = try await studentRepository.find(byID: existingToken.$user.id, on: db) else {
                        return .notFound
                    }

                    guard student.status.isLoginPermitted else {
                        throw Abort(.unauthorized, reason: "Account is suspended or inactive.")
                    }

                    // 3. Issue fresh token pair within the same transaction
                    let pair = try await generateTokenPair(for: student, on: req, db: db)
                    return .issued(pair)
                }
            }

            switch outcome {
            case .issued(let pair):
                return pair

            case .notFound:
                throw Abort(.unauthorized, reason: "Invalid refresh token.")

            case .reuseDetected(let userID):
                req.logger.critical("Compromised token reuse detected for user ID: \(userID). Revoked all sessions.")
                throw Abort(.unauthorized, reason: "Invalid authentication state. Please log in again.")

            case .expired:
                throw Abort(.unauthorized, reason: "Refresh token has expired.")
            }
        } catch {
            if let abort = error as? (any AbortError) {
                throw abort
            }
            req.logger.warning("Database error during refresh token rotation: \(error)")
            throw Abort(.unauthorized, reason: "Invalid authentication state. Please log in again.")
        }
    }

    // MARK: - Refresh Token Revocation & Lifecycle Cleanup

    func revokeRefreshToken(rawToken: String, on db: any Database) async throws {
        let tokenHash = Self.hashToken(rawToken)
        try await refreshTokenRepository.revoke(byHash: tokenHash, on: db)
    }

    func revokeAllSessions(for studentID: UUID, on db: any Database) async throws {
        try await refreshTokenRepository.revokeAll(forUserID: studentID, on: db)
    }

    func cleanupExpiredTokens(on db: any Database) async throws -> Int {
        try await refreshTokenRepository.deleteExpiredOrRevoked(before: Date(), on: db)
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

        let isRevoked = try await shared.revokedTokenRepository.isRevoked(jti: payload.jti.value, on: request.db)
        if isRevoked {
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

        guard let student = try await shared.studentRepository.find(byID: payload.studentID, on: request.db) else {
            throw Abort(.unauthorized, reason: "Invalid token")
        }

        request.authenticatedStudent = student
        request.authenticatedToken = payload
        request.authenticatedRole = payload.role

        return student
    }

    /// Revokes an access token's JTI.
    static func revokeToken(_ payload: StudentToken, on database: any Database) async throws {
        try await shared.revokedTokenRepository.revoke(jti: payload.jti.value, expiresAt: payload.exp.value, on: database)
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
