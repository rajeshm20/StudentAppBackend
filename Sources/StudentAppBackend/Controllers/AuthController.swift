//
//  AuthController.swift
//  StudentAppBackend
//
//  Created by Rajesh Mani on 07/08/25.
//


// MARK: - AuthController.swift
import Vapor
import JWTKit
import JWT

struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let authRoutes = routes.grouped("auth")
        authRoutes.post("signup", use: signup)
        authRoutes.post("login", use: login)
    }
    
    func signup(_ req: Request) async throws -> Student.Public {
        let create = try req.content.decode(Student.CreateRequest.self)

        let hashedPassword = try Bcrypt.hash(create.password)

        let student = Student(
            id: UUID(),
            name: create.name,
            email: create.email,
            passwordHash: hashedPassword
        )

        try await student.save(on: req.db)
        return student.convertToPublic()
    }

    func login(req: Request) async throws -> LoginResponse {
        let credentials = try req.content.decode(Student.LoginRequest.self)
        guard let student = try await StudentService.shared.authenticate(credentials: credentials, on: req.db) else {
            throw Abort(.unauthorized, reason: "Invalid email or password")
        }
//        return HTTPStatus.ok
        let expiration = ExpirationClaim(value: .init(timeIntervalSinceNow: 3600)) // 1 hour
        let payload = StudentToken(exp: expiration, studentID: try student.requireID())
        let token = try req.jwt.sign(payload)
        return LoginResponse.init(user: student.convertToPublic(), token: TokenResponse(token: token), status: .ok)
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
