//
//  AuthController.swift
//  StudentAppBackend
//
//  Created by Rajesh Mani on 07/08/25.
//


// MARK: - AuthController.swift
import Vapor
import Fluent
import JWTKit
import JWT

struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let authRoutes = routes.grouped("auth")
        authRoutes.post("signup", use: signup)
        authRoutes.post("login", use: login)
        authRoutes.post("logout", use: logout)
    }
    
    func signup(_ req: Request) async throws -> Student.Public {
        let create = try req.content.decode(Student.CreateRequest.self)

        let hashedPassword = try Bcrypt.hash(create.password)

        let student = Student(
            id: UUID(),
            name: create.name,
            email: create.email,
            passwordHash: hashedPassword,
            dob: create.dob,
            phoneNumber: create.phoneNumber
        )

        try await student.save(on: req.db)
        return student.convertToPublic()
    }

    func login(req: Request) async throws -> LoginResponse {
        let credentials = try req.content.decode(Student.LoginRequest.self)
        guard let student = try await StudentService.shared.authenticate(credentials: credentials, on: req.db) else {
            throw LoginError(status: .unauthorized, message: Abort(.unauthorized, reason: "Invalid email or password").localizedDescription)
        }
        let expiration = ExpirationClaim(value: .init(timeIntervalSinceNow: 60)) // 1 hour
        let payload = StudentToken(exp: expiration, studentID: try student.requireID(), jti: IDClaim(value: UUID().uuidString))
        let token = try req.jwt.sign(payload)
        return LoginResponse.init(user: student.convertToPublic(), token: TokenResponse(token: token), status: .ok)
    }

    func logout(_ req: Request) async throws -> LogoutResponse {
        guard let bearer = req.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Missing or invalid Authorization header")
        }

        let payload = try req.jwt.verify(bearer.token, as: StudentToken.self)
        if try await RevokedToken.query(on: req.db).filter(\.$jti == payload.jti.value).first() != nil {
            throw Abort(.unauthorized, reason: "Token already revoked")
        }

        let revokedToken = RevokedToken(jti: payload.jti.value, expiresAt: payload.exp.value)
        try await revokedToken.save(on: req.db)
        return LogoutResponse(message: "Logout successful")
    }
}
struct TokenResponse: Content {
    let token: String
}

struct LoginResponse: Content {
    let user: Student.Public
    let token: TokenResponse
    let status: HTTPStatus
}
struct LogoutResponse: Content {
    let message: String
}

struct LoginError: Error, Codable, Content {
    let status: HTTPStatus
    let message: String
}
