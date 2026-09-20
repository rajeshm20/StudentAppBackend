// MARK: - AuthController.swift // Authentication endpoints: signup, login, refresh, forgot-password, logout.
// Controllers are thin — all business logic lives in services.
// Do NOT add authorization logic here; use RoleMiddleware and AuthorizationService.

import Vapor
import Fluent
import JWTKit
import JWT

struct AuthController: RouteCollection {
    private let studentService: any StudentServiceProtocol
    private let tokenService: any TokenServiceProtocol
    private let studentRepository: any StudentRepository
    private let passwordResetRepository: any PasswordResetRepository

    init(
        studentService: any StudentServiceProtocol = StudentService.shared,
        tokenService: any TokenServiceProtocol = TokenService.shared,
        studentRepository: any StudentRepository = DatabaseStudentRepository(),
        passwordResetRepository: any PasswordResetRepository = DatabasePasswordResetRepository()
    ) {
        self.studentService = studentService
        self.tokenService = tokenService
        self.studentRepository = studentRepository
        self.passwordResetRepository = passwordResetRepository
    }

    func boot(routes: any RoutesBuilder) throws {
        let authRoutes = routes.grouped("auth")

        // MARK: - Student Signup (New Canonical Endpoint)
        // POST /auth/signup/student
        authRoutes.post("signup", "student", use: signupStudent)

        // MARK: - Legacy Signup Alias (Backward Compatibility)
        // POST /auth/signup  — kept to avoid breaking existing clients
        // Delegates to the legacySignup handler.
        authRoutes.post("signup", use: legacySignup)

        // MARK: - Authentication
        authRoutes.post("login", use: login)
        authRoutes.post("refresh", use: refresh)
        authRoutes.post("forgot-password", use: forgotPassword)
        authRoutes.post("verify-reset-code", use: verifyResetCode)
        authRoutes.post("reset-password", use: resetPassword)

        // MARK: - Protected Endpoints (require JWT)
        let protectedAuth = authRoutes.grouped(JWTAuthMiddleware())
        protectedAuth.post("logout", use: logout)
    }

    // MARK: - Student Signup Handler

    /// POST /auth/signup/student
    ///
    /// Assigns role=student server-side. Any role value provided by the client is ignored.
    /// confirmPassword is validated and then discarded — never persisted.
    @Sendable
    func signupStudent(_ req: Request) async throws -> Student.Public {
        let input = try req.content.decode(StudentSignupRequest.self)

        // Run validation — returns first-class structured errors
        let validationErrors = validateStudentSignupRequest(
            firstName: input.firstName,
            lastName: input.lastName,
            email: input.email,
            password: input.password,
            confirmPassword: input.confirmPassword,
            countryCode: input.countryCode,
            contactNumber: input.contactNumber
        )

        if !validationErrors.isEmpty {
            let errorMessages = validationErrors.map { "\($0.field): \($0.message)" }.joined(separator: "; ")
            throw Abort(.badRequest, reason: "Validation failed: \(errorMessages)")
        }

        let student = try await studentService.signupStudent(request: input, on: req.db)
        return student.convertToPublic()
    }

    // MARK: - Legacy Signup Handler

    /// POST /auth/signup (Backward Compatibility)
    @Sendable
    func legacySignup(_ req: Request) async throws -> Student.Public {
        let input = try req.content.decode(Student.CreateRequest.self)

        let validationErrors = validateStudentCreateRequest(
            name: input.name,
            email: input.email,
            password: input.password,
            dob: input.dob,
            phoneNumber: input.phoneNumber
        )

        if !validationErrors.isEmpty {
            let errorMessages = validationErrors.map { "\($0.field): \($0.message)" }.joined(separator: "; ")
            throw Abort(.badRequest, reason: "Validation failed: \(errorMessages)")
        }

        let normalizedEmail = input.email.lowercased().trimmingCharacters(in: .whitespaces)
        if try await studentRepository.find(byEmail: normalizedEmail, on: req.db) != nil {
            throw Abort(.conflict, reason: "An account with this email already exists", identifier: "EMAIL_ALREADY_EXISTS")
        }

        let hashedPassword = try Bcrypt.hash(input.password)
        let student = Student(
            id: UUID(),
            firstName: nil,
            lastName: nil,
            name: input.name.trimmingCharacters(in: .whitespaces),
            email: normalizedEmail,
            passwordHash: hashedPassword,
            role: .student,
            status: .active,
            dob: input.dob,
            phoneNumber: input.phoneNumber
        )

        do {
            try await studentRepository.create(student, on: req.db)
        } catch {
            throw StudentService.mapDatabaseError(error)
        }
        return student.convertToPublic()
    }

    // MARK: - Login Handler

    /// POST /auth/login
    ///
    /// Returns the authenticated user's role and dual token pair.
    /// The client must NOT send a role; role is always determined from the database.
    @Sendable
    func login(req: Request) async throws -> LoginResponse {
        let credentials = try req.content.decode(Student.LoginRequest.self)

        guard let student = try await studentService.authenticate(credentials: credentials, on: req.db) else {
            // Generic message: do not reveal whether email exists or account is suspended
            throw Abort(.unauthorized, reason: "Invalid email or password")
        }

        let tokenPair = try await tokenService.generateTokenPair(for: student, on: req)
        return LoginResponse(
            user: student.convertToPublic(),
            token: TokenResponse(
                token: tokenPair.accessToken,
                refreshToken: tokenPair.refreshToken,
                tokenType: tokenPair.tokenType,
                expiresIn: tokenPair.expiresIn
            ),
            status: .ok,
            tokens: tokenPair
        )
    }

    // MARK: - Refresh Token Rotation Handler

    /// POST /auth/refresh
    ///
    /// Rotates the refresh token and returns a new access/refresh token pair.
    /// If an already revoked token is provided, all sessions for the user are revoked immediately.
    @Sendable
    func refresh(req: Request) async throws -> TokenPairResponse {
        let refreshRequest = try req.content.decode(RefreshRequest.self)
        return try await tokenService.rotateRefreshToken(rawToken: refreshRequest.refreshToken, on: req)
    }

    // MARK: - Forgot Password Handler

    @Sendable
    func forgotPassword(_ req: Request) async throws -> ForgotPasswordResponse {
        let request = try req.content.decode(ForgotPasswordRequest.self)
        let response = ForgotPasswordResponse.forgotPasswordSubmitted
        let normalizedEmail = request.email.lowercased().trimmingCharacters(in: .whitespaces)

        guard let student = try await studentRepository.find(byEmail: normalizedEmail, on: req.db) else {
            return response // enumeration-safe: same response regardless
        }

        let code = String(format: "%06d", Int.random(in: 0...999999))

        let resetToken = PasswordResetToken(
            email: student.email,
            code: code,
            codeExpiresAt: Date().addingTimeInterval(10 * 60)
        )
        try await passwordResetRepository.create(resetToken, on: req.db)

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

    // MARK: - Verify Reset Code

    @Sendable
    func verifyResetCode(_ req: Request) async throws -> VerifyResetCodeResponse {
        let request = try req.content.decode(VerifyResetCodeRequest.self)
        let normalizedEmail = request.email.lowercased().trimmingCharacters(in: .whitespaces)

        guard let resetToken = try await passwordResetRepository.findLatestActiveCode(forEmail: normalizedEmail, on: req.db) else {
            return VerifyResetCodeResponse(success: false, message: "Invalid or expired code.", sessionToken: nil)
        }

        if resetToken.attempts >= 3 {
            resetToken.used = true
            try await passwordResetRepository.update(resetToken, on: req.db)
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
            try await passwordResetRepository.update(resetToken, on: req.db)
            return VerifyResetCodeResponse(success: false, message: "Invalid code.", sessionToken: nil)
        }

        let sessionToken = [UInt8].random(count: 32).base64.replacingOccurrences(of: "/", with: "_")
        resetToken.verified = true
        resetToken.sessionToken = sessionToken
        resetToken.sessionExpiresAt = Date().addingTimeInterval(15 * 60)
        try await passwordResetRepository.update(resetToken, on: req.db)

        return VerifyResetCodeResponse(success: true, message: "Code verified.", sessionToken: sessionToken)
    }

    // MARK: - Reset Password

    @Sendable
    func resetPassword(_ req: Request) async throws -> ResetPasswordResponse {
        let request = try req.content.decode(ResetPasswordRequest.self)
        let normalizedEmail = request.email.lowercased().trimmingCharacters(in: .whitespaces)

        guard request.newPassword == request.confirmPassword else {
            throw Abort(.badRequest, reason: "Passwords do not match")
        }
        guard request.newPassword.count >= 8 else {
            throw Abort(.badRequest, reason: "Password must be at least 8 characters")
        }

        guard let resetToken = try await passwordResetRepository.findVerifiedSession(forEmail: normalizedEmail, sessionToken: request.sessionToken, on: req.db) else {
            throw Abort(.badRequest, reason: "Invalid or expired reset session")
        }

        guard let sessionExpiresAt = resetToken.sessionExpiresAt, sessionExpiresAt > Date() else {
            throw Abort(.badRequest, reason: "Reset session has expired. Please start over.")
        }

        guard let student = try await studentRepository.find(byEmail: normalizedEmail, on: req.db) else {
            throw Abort(.notFound, reason: "Account not found")
        }

        student.passwordHash = try Bcrypt.hash(request.newPassword)
        try await studentRepository.update(student, on: req.db)

        resetToken.used = true
        try await passwordResetRepository.update(resetToken, on: req.db)

        return ResetPasswordResponse(success: true, message: "Password reset successfully")
    }

    // MARK: - Logout

    @Sendable
    func logout(_ req: Request) async throws -> LogoutResponse {
        let student = try await TokenService.authenticateStudent(from: req)

        guard let payload = req.authenticatedToken else {
            throw Abort(.unauthorized, reason: "Missing or invalid Authorization header")
        }

        let studentID = try student.requireID()

        // Atomically coordinate access-token revocation and session-family revocation inside an enclosing transaction
        try await req.db.transaction { db in
            // 1. Revoke the active JWT access token
            try await TokenService.revokeToken(payload, on: db)

            // 2. Revoke all active refresh tokens for this user identity (holding user row lock)
            try await self.tokenService.revokeAllSessions(for: studentID, on: db)
        }

        return LogoutResponse(message: "Logout successful")
    }
}

// MARK: - Response DTOs

struct TokenResponse: Content, Sendable {
    let token: String
    let refreshToken: String?
    let tokenType: String?
    let expiresIn: Int?

    init(
        token: String,
        refreshToken: String? = nil,
        tokenType: String? = nil,
        expiresIn: Int? = nil
    ) {
        self.token = token
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
    }
}

struct LoginResponse: Content, Sendable {
    let user: Student.Public
    let token: TokenResponse
    let status: HTTPStatus
    let tokens: TokenPairResponse?

    init(
        user: Student.Public,
        token: TokenResponse,
        status: HTTPStatus,
        tokens: TokenPairResponse? = nil
    ) {
        self.user = user
        self.token = token
        self.status = status
        self.tokens = tokens
    }
}

struct LogoutResponse: Content, Sendable {
    let message: String

    init(message: String) {
        self.message = message
    }
}

struct LoginError: Error, Codable, Content, Sendable {
    let status: HTTPStatus
    let message: String

    init(status: HTTPStatus, message: String) {
        self.status = status
        self.message = message
    }
}
