import Fluent
import JWTKit
import JWT
import Vapor

enum TokenService {
    static func signAccessToken(for student: Student, on request: Request) throws -> String {
        let expiration = ExpirationClaim(value: Date(timeIntervalSinceNow: AppConfig.jwtAccessTTL()))
        let payload = StudentToken(
            exp: expiration,
            studentID: try student.requireID(),
            jti: IDClaim(value: UUID().uuidString)
        )
        return try request.jwt.sign(payload)
    }

    static func verifyAccessToken(_ token: String, on request: Request) async throws -> StudentToken {
        let payload = try request.jwt.verify(token, as: StudentToken.self)

        if try await RevokedToken.query(on: request.db)
            .filter(\.$jti == payload.jti.value)
            .first() != nil {
            throw Abort(.unauthorized, reason: "Token revoked")
        }

        return payload
    }

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
        return student
    }

    static func revokeToken(_ payload: StudentToken, on database: any Database) async throws {
        let revokedToken = RevokedToken(jti: payload.jti.value, expiresAt: payload.exp.value)
        try await revokedToken.save(on: database)
    }
}

extension Request {
    struct AuthenticatedStudentKey: StorageKey {
        typealias Value = Student
    }

    struct AuthenticatedTokenKey: StorageKey {
        typealias Value = StudentToken
    }

    var authenticatedStudent: Student? {
        get { storage[AuthenticatedStudentKey.self] }
        set { storage[AuthenticatedStudentKey.self] = newValue }
    }

    var authenticatedToken: StudentToken? {
        get { storage[AuthenticatedTokenKey.self] }
        set { storage[AuthenticatedTokenKey.self] = newValue }
    }
}
