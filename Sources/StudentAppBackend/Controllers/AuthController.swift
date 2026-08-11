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
        authRoutes.post("forgot-password", use: forgotPassword)
        authRoutes.post("verify-reset-code", use: verifyResetCode)
        authRoutes.post("reset-password", use: resetPassword)

        let protectedAuth = authRoutes.grouped(JWTAuthMiddleware())
        protectedAuth.post("logout", use: logout)
    }
    
    func signup(_ req: Request) async throws -> Student.Public {
        let create = try req.content.decode(Student.CreateRequest.self)
        
        // Run Vapor's automatic validations
        try Student.CreateRequest.validate(content: req)
        
        // Run additional validation checks not covered by Vapor validators
        let validationErrors = validateStudentCreateRequest(
            name: create.name,
            email: create.email,
            password: create.password,
            dob: create.dob,
            phoneNumber: create.phoneNumber
        )
        
        if !validationErrors.isEmpty {
            let errorMessages = validationErrors.map { "\($0.field): \($0.message)" }.joined(separator: "; ")
            throw Abort(.badRequest, reason: "Validation failed: \(errorMessages)")
        }

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
            throw Abort(.unauthorized, reason: "Invalid email or password")
        }
        let token = try TokenService.signAccessToken(for: student, on: req)
        return LoginResponse(user: student.convertToPublic(), token: TokenResponse(token: token), status: .ok)
    }
    func forgotPassword(_ req: Request) async throws -> ForgotPasswordResponse {
        let request = try req.content.decode(ForgotPasswordRequest.self)
        let response = ForgotPasswordResponse.forgotPasswordSubmitted

        guard let student = try await Student.query(on: req.db)
            .filter(\.$email == request.email)
            .first()
        else {
            return response
        }

        // 6-digit numeric code, 10-minute expiry
        let code = String(format: "%06d", Int.random(in: 0...999999))

        let resetToken = PasswordResetToken(
            email: student.email,
            code: code,
            codeExpiresAt: Date().addingTimeInterval(10 * 60)
        )
        try await resetToken.save(on: req.db)
        do {
            try await req.application.emailService.send(
                to: student.email,
                subject: "Your password reset code",
                body: """
            Your verification code is: \(code)
            
            This code expires in 10 minutes. If you didn't request this, you can ignore this email.
            """
            )
        } catch {
            req.logger.warning("Failed to send email: \(error)")
            throw Abort(.internalServerError, reason: "Could not send reset email")
        }

        return response
    }

    func verifyResetCode(_ req: Request) async throws -> VerifyResetCodeResponse {
        let request = try req.content.decode(VerifyResetCodeRequest.self)

        guard let resetToken = try await PasswordResetToken.query(on: req.db)
            .filter(\.$email == request.email)
            .filter(\.$used == false)
            .filter(\.$verified == false)
            .sort(\.$codeExpiresAt, .descending)
            .first()
        else {
            return VerifyResetCodeResponse(success: false, message: "Invalid or expired code.", sessionToken: nil)
        }

        if resetToken.attempts >= 3 {
            resetToken.used = true
            try await resetToken.save(on: req.db)
            return VerifyResetCodeResponse(success: false, message: "Too many failed attempts. Please request a new code.", sessionToken: nil)
        }

        guard resetToken.codeExpiresAt > Date() else {
            return VerifyResetCodeResponse(success: false, message: "Code has expired. Please request a new one.", sessionToken: nil)
        }

        guard resetToken.code == request.code else {
            resetToken.attempts += 1
            if resetToken.attempts >= 3 {
                resetToken.used = true
            }
            try await resetToken.save(on: req.db)
            return VerifyResetCodeResponse(success: false, message: "Invalid code.", sessionToken: nil)
        }

        // Issue a short-lived session token — this is what screen 2 will actually use,
        // so the 6-digit code itself can't be replayed indefinitely.
        let sessionToken = [UInt8].random(count: 32).base64.replacingOccurrences(of: "/", with: "_")
        resetToken.verified = true
        resetToken.sessionToken = sessionToken
        resetToken.sessionExpiresAt = Date().addingTimeInterval(15 * 60)
        try await resetToken.save(on: req.db)

        return VerifyResetCodeResponse(success: true, message: "Code verified.", sessionToken: sessionToken)
    }

    func resetPassword(_ req: Request) async throws -> ResetPasswordResponse {
        let request = try req.content.decode(ResetPasswordRequest.self)

        guard request.newPassword == request.confirmPassword else {
            throw Abort(.badRequest, reason: "Passwords do not match")
        }
        guard request.newPassword.count >= 8 else {
            throw Abort(.badRequest, reason: "Password must be at least 8 characters")
        }

        guard let resetToken = try await PasswordResetToken.query(on: req.db)
            .filter(\.$email == request.email)
            .filter(\.$sessionToken == request.sessionToken)
            .filter(\.$verified == true)
            .filter(\.$used == false)
            .first()
        else {
            throw Abort(.badRequest, reason: "Invalid or expired reset session")
        }

        guard let sessionExpiresAt = resetToken.sessionExpiresAt, sessionExpiresAt > Date() else {
            throw Abort(.badRequest, reason: "Reset session has expired. Please start over.")
        }

        guard let student = try await Student.query(on: req.db)
            .filter(\.$email == request.email)
            .first()
        else {
            throw Abort(.notFound, reason: "Student not found")
        }

        student.passwordHash = try Bcrypt.hash(request.newPassword)
        try await student.save(on: req.db)

        resetToken.used = true
        try await resetToken.save(on: req.db)

        return ResetPasswordResponse(success: true, message: "Password reset successfully")
    }

    func logout(_ req: Request) async throws -> LogoutResponse {
        _ = try await TokenService.authenticateStudent(from: req)

        guard let payload = req.authenticatedToken else {
            throw Abort(.unauthorized, reason: "Missing or invalid Authorization header")
        }

        try await TokenService.revokeToken(payload, on: req.db)
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
