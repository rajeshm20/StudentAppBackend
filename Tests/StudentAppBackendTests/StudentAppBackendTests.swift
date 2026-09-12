// MARK: - StudentAppBackendTests.swift
// Comprehensive integration tests for authentication, authorization, and RBAC.
// All tests run against an in-memory SQLite database (not production MySQL).
// Tests are serialized to prevent race conditions on shared test state.

import Fluent
import NIOSSL
import Testing
import Vapor
import VaporTesting
import XCTest

@testable import StudentAppBackend

// MARK: - Test Suite

@Suite("App Tests with DB", .serialized)
struct StudentAppBackendTests {

    // MARK: - Test Harness

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try configure(app)
            try await app.autoMigrate()
            try await test(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    // MARK: - Shared Helpers

    /// Registers a student via the new POST /auth/signup/student endpoint.
    private func registerStudent(
        firstName: String = "John",
        lastName: String = "Doe",
        email: String = "john@example.com",
        password: String = "secret123",
        confirmPassword: String? = nil,
        countryCode: String = "+91",
        contactNumber: String = "9876543210",
        on app: Application
    ) async throws -> StudentPublicResponse {
        let payload = NewSignupPayload(
            firstName: firstName,
            lastName: lastName,
            email: email,
            password: password,
            confirmPassword: confirmPassword ?? password,
            countryCode: countryCode,
            contactNumber: contactNumber
        )
        var result: StudentPublicResponse?
        try await app.testing().test(
            .POST, "auth/signup/student",
            beforeRequest: { req in
                try req.content.encode(payload)
            },
            afterResponse: { res async throws in
                result = try res.content.decode(StudentPublicResponse.self)
            })
        return result!
    }

    /// Logs in and returns a JWT token.
    private func login(email: String, password: String, on app: Application) async throws -> String
    {
        let loginPayload = ["email": email, "password": password]
        var token = ""
        try await app.testing().test(
            .POST, "auth/login",
            beforeRequest: { req in
                try req.content.encode(loginPayload)
            },
            afterResponse: { res async throws in
                let loginResponse = try res.content.decode(LoginResponseTest.self)
                token = loginResponse.token.token
            })
        return token
    }

    /// Injects a user with a specific role directly into the database (used for RBAC tests).
    private func seedUser(
        role: String,
        email: String,
        password: String = "secret123",
        on db: any Database
    ) async throws -> UUID {
        let hashedPassword = try Bcrypt.hash(password)
        let student = Student(
            id: UUID(),
            firstName: "Seed",
            lastName: role.capitalized,
            name: "Seed \(role.capitalized)",
            email: email,
            passwordHash: hashedPassword,
            role: UserRole(rawValue: role) ?? .student,
            status: .active
        )
        try await student.save(on: db)
        return try student.requireID()
    }

    // MARK: =========================================================
    // MARK: - Legacy Signup Tests (POST /auth/signup — Backward Compat)
    // MARK: =========================================================

    @Test("Legacy signup route still works")
    func testLegacySignup() async throws {
        try await withApp { app in
            let payload = [
                "name": "Karthick", "email": "karthickt@example.com", "password": "secret123",
            ]
            try await app.testing().test(
                .POST, "auth/signup",
                beforeRequest: { req in
                    try req.content.encode(payload)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    do {
                        let body = try res.content.decode(StudentPublicResponse.self)
                        #expect(body.email == "karthickt@example.com")
                        #expect(body.role == "student")  // always student
                    } catch {
                        XCTFail("Failed to decode response: \(error)")
                    }
                })
        }
    }

    // MARK: =========================================================
    // MARK: - New Student Signup Tests (POST /auth/signup/student)
    // MARK: =========================================================

    @Test("Valid student signup returns student role")
    func testNewSignupSuccess() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John",
                lastName: "Doe",
                email: "john@example.com",
                password: "secret123",
                confirmPassword: "secret123",
                countryCode: "+91",
                contactNumber: "9876543210"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    do {
                        let body = try res.content.decode(StudentPublicResponse.self)
                        #expect(body.email == "john@example.com")
                        #expect(body.firstName == "John")
                        #expect(body.lastName == "Doe")
                        #expect(body.role == "student")  // always student
                        #expect(body.contactNumber == "+919876543210")  // E.164 normalized
                    } catch {
                        XCTFail("Failed to decode response: \(error)")
                    }
                })
        }
    }

    @Test("Signup: role escalation blocked — client sends admin, gets student")
    func testSignupRoleEscalationBlocked() async throws {
        // The new signup endpoint has no role field in the request,
        // but even if a raw JSON body includes a role key, it must be ignored.
        try await withApp { app in
            // Inject via raw JSON with a role field
            struct PayloadWithRole: Content {
                let firstName: String
                let lastName: String
                let email: String
                let password: String
                let confirmPassword: String
                let countryCode: String
                let contactNumber: String
                let role: String  // should be ignored
            }
            let payload = PayloadWithRole(
                firstName: "Evil",
                lastName: "Hacker",
                email: "hacker@example.com",
                password: "secret123",
                confirmPassword: "secret123",
                countryCode: "+1",
                contactNumber: "2025551234",
                role: "admin"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    do {
                        let body = try res.content.decode(StudentPublicResponse.self)
                        #expect(body.role == "student")  // must be student, not admin
                    } catch {
                        XCTFail("Failed to decode response: \(error)")
                    }
                })
        }
    }

    @Test("Signup: missing firstName returns 400")
    func testSignupMissingFirstName() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "", lastName: "Doe", email: "test@example.com",
                password: "secret123", confirmPassword: "secret123", countryCode: "+91",
                contactNumber: "9876543210")
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Signup: missing lastName returns 400")
    func testSignupMissingLastName() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "", email: "test@example.com",
                password: "secret123", confirmPassword: "secret123", countryCode: "+91",
                contactNumber: "9876543210")
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Signup: missing email returns 400")
    func testSignupMissingEmail() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "",
                password: "secret123", confirmPassword: "secret123", countryCode: "+91",
                contactNumber: "9876543210")
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Signup: invalid email format returns 400")
    func testSignupInvalidEmail() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "not-an-email",
                password: "secret123", confirmPassword: "secret123", countryCode: "+91",
                contactNumber: "9876543210")
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Signup: missing password returns 400")
    func testSignupMissingPassword() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "test@example.com",
                password: "", confirmPassword: "", countryCode: "+91", contactNumber: "9876543210")
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Signup: password too short returns 400")
    func testSignupPasswordTooShort() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "test@example.com",
                password: "abc1", confirmPassword: "abc1", countryCode: "+91",
                contactNumber: "9876543210")
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Signup: password/confirmPassword mismatch returns 400")
    func testSignupPasswordMismatch() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "test@example.com",
                password: "secret123", confirmPassword: "different1", countryCode: "+91",
                contactNumber: "9876543210")
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Signup: missing countryCode returns 400")
    func testSignupMissingCountryCode() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "test@example.com",
                password: "secret123", confirmPassword: "secret123", countryCode: "",
                contactNumber: "9876543210")
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Signup: invalid countryCode (no + prefix) returns 400")
    func testSignupInvalidCountryCode() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "test@example.com",
                password: "secret123", confirmPassword: "secret123", countryCode: "91",
                contactNumber: "9876543210")
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Signup: invalid contactNumber (non-digits) returns 400")
    func testSignupInvalidContactNumber() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "test@example.com",
                password: "secret123", confirmPassword: "secret123", countryCode: "+91",
                contactNumber: "98765abc")
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Signup: contactNumber too short returns 400")
    func testSignupContactNumberTooShort() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "test@example.com",
                password: "secret123", confirmPassword: "secret123", countryCode: "+91",
                contactNumber: "123")
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Signup: duplicate email returns 409")
    func testSignupDuplicateEmail() async throws {
        try await withApp { app in
            let email = "dup@example.com"
            let p1 = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: email,
                password: "secret123", confirmPassword: "secret123", countryCode: "+91",
                contactNumber: "9876543210")
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(p1)
                })
            let p2 = NewSignupPayload(
                firstName: "Jane", lastName: "Doe", email: email,
                password: "secret123", confirmPassword: "secret123", countryCode: "+44",
                contactNumber: "7890123456")
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(p2)
                },
                afterResponse: { res async in
                    #expect(res.status == .conflict)
                })
        }
    }

    @Test("Signup: duplicate phone number returns 409")
    func testSignupDuplicatePhone() async throws {
        try await withApp { app in
            let phone = "9876543210"
            let p1 = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "john1@example.com",
                password: "secret123", confirmPassword: "secret123", countryCode: "+91",
                contactNumber: phone)
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(p1)
                })
            let p2 = NewSignupPayload(
                firstName: "Jane", lastName: "Doe", email: "jane1@example.com",
                password: "secret123", confirmPassword: "secret123", countryCode: "+91",
                contactNumber: phone)
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(p2)
                },
                afterResponse: { res async in
                    #expect(res.status == .conflict)
                })
        }
    }

    // MARK: =========================================================
    // MARK: - Login Tests
    // MARK: =========================================================

    @Test("Login: valid student login returns role in response")
    func testLoginReturnsRole() async throws {
        try await withApp { app in
            _ = try await registerStudent(email: "login@example.com", on: app)
            let loginPayload = ["email": "login@example.com", "password": "secret123"]
            try await app.testing().test(
                .POST, "auth/login",
                beforeRequest: { req in
                    try req.content.encode(loginPayload)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    do {
                        let body = try res.content.decode(LoginResponseTest.self)
                        #expect(body.user.role == "student")
                        #expect(!body.token.token.isEmpty)
                    } catch {
                        XCTFail("Failed to decode login response: \(error)")
                    }
                })
        }
    }

    @Test("Login: wrong password returns 401")
    func testLoginWrongPassword() async throws {
        try await withApp { app in
            _ = try await registerStudent(email: "wrongpw@example.com", on: app)
            let loginPayload = ["email": "wrongpw@example.com", "password": "wrongpassword1"]
            try await app.testing().test(
                .POST, "auth/login",
                beforeRequest: { req in
                    try req.content.encode(loginPayload)
                },
                afterResponse: { res async in
                    #expect(res.status == .unauthorized)
                })
        }
    }

    @Test("Login: non-existent email returns 401 (enumeration safe)")
    func testLoginNonExistentEmail() async throws {
        try await withApp { app in
            let loginPayload = ["email": "ghost@example.com", "password": "secret123"]
            try await app.testing().test(
                .POST, "auth/login",
                beforeRequest: { req in
                    try req.content.encode(loginPayload)
                },
                afterResponse: { res async in
                    #expect(res.status == .unauthorized)
                })
        }
    }

    @Test("Login: suspended account returns 401 (no status leak)")
    func testLoginSuspendedAccount() async throws {
        try await withApp { app in
            _ = try await registerStudent(email: "suspended@example.com", on: app)
            // Directly suspend the account in the DB
            if let student = try await Student.query(on: app.db)
                .filter(\.$email == "suspended@example.com").first()
            {
                student.status = .suspended
                try await student.save(on: app.db)
            }
            let loginPayload = ["email": "suspended@example.com", "password": "secret123"]
            try await app.testing().test(
                .POST, "auth/login",
                beforeRequest: { req in
                    try req.content.encode(loginPayload)
                },
                afterResponse: { res async in
                    #expect(res.status == .unauthorized)
                })
        }
    }

    @Test("Login: inactive account returns 401 (no status leak)")
    func testLoginInactiveAccount() async throws {
        try await withApp { app in
            _ = try await registerStudent(email: "inactive@example.com", on: app)
            if let student = try await Student.query(on: app.db)
                .filter(\.$email == "inactive@example.com").first()
            {
                student.status = .inactive
                try await student.save(on: app.db)
            }
            let loginPayload = ["email": "inactive@example.com", "password": "secret123"]
            try await app.testing().test(
                .POST, "auth/login",
                beforeRequest: { req in
                    try req.content.encode(loginPayload)
                },
                afterResponse: { res async in
                    #expect(res.status == .unauthorized)
                })
        }
    }

    // MARK: =========================================================
    // MARK: - Logout Tests
    // MARK: =========================================================

    @Test("Logout: valid token succeeds")
    func testLogout() async throws {
        try await withApp { app in
            _ = try await registerStudent(email: "logout@example.com", on: app)
            let token = try await login(email: "logout@example.com", password: "secret123", on: app)
            try await app.testing().test(
                .POST, "auth/logout",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let logoutResponse = try res.content.decode(LogoutResponseTest.self)
                    #expect(logoutResponse.message == "Logout successful")
                })
        }
    }

    @Test("Logout: no token returns 401")
    func testLogoutRequiresAuth() async throws {
        try await withApp { app in
            try await app.testing().test(
                .POST, "auth/logout",
                afterResponse: { res async in
                    #expect(res.status == .unauthorized)
                })
        }
    }

    @Test("Logout: revoked token cannot be reused")
    func testLogoutRevokedToken() async throws {
        try await withApp { app in
            _ = try await registerStudent(email: "revoke@example.com", on: app)
            let token = try await login(email: "revoke@example.com", password: "secret123", on: app)
            try await app.testing().test(
                .POST, "auth/logout",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                })
            try await app.testing().test(
                .POST, "auth/logout",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                })
        }
    }

    // MARK: =========================================================
    // MARK: - Resource Authorization Tests (GET /students/:id)
    // MARK: =========================================================

    @Test("Student can access own record")
    func testStudentCanAccessOwnRecord() async throws {
        try await withApp { app in
            let created = try await registerStudent(email: "own@example.com", on: app)
            let token = try await login(email: "own@example.com", password: "secret123", on: app)
            guard let id = created.id else {
                XCTFail("No ID")
                return
            }
            try await app.testing().test(
                .GET, "students/\(id)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                })
        }
    }

    @Test("Student cannot access another student's record (IDOR prevention)")
    func testStudentCannotAccessOtherStudentRecord() async throws {
        try await withApp { app in
            _ = try await registerStudent(
                email: "studentA@example.com", contactNumber: "9876500001", on: app)
            let studentB = try await registerStudent(
                email: "studentB@example.com", contactNumber: "9876500002", on: app)
            let tokenA = try await login(
                email: "studentA@example.com", password: "secret123", on: app)
            guard let idB = studentB.id else {
                XCTFail("No ID")
                return
            }
            try await app.testing().test(
                .GET, "students/\(idB)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: tokenA)
                },
                afterResponse: { res async in
                    #expect(res.status == .forbidden)
                })
        }
    }

    @Test("Unauthenticated request to GET /students/:id returns 401")
    func testUnauthenticatedStudentAccess() async throws {
        try await withApp { app in
            let created = try await registerStudent(email: "unauth@example.com", on: app)
            guard let id = created.id else {
                XCTFail("No ID")
                return
            }
            try await app.testing().test(
                .GET, "students/\(id)",
                afterResponse: { res async in
                    #expect(res.status == .unauthorized)
                })
        }
    }

    @Test("Admin can access any student record")
    func testAdminCanAccessAnyStudentRecord() async throws {
        try await withApp { app in
            let student = try await registerStudent(email: "student@rbac.com", on: app)
            let adminID = try await seedUser(role: "admin", email: "admin@rbac.com", on: app.db)
            let adminToken = try await login(
                email: "admin@rbac.com", password: "secret123", on: app)
            guard let studentID = student.id else {
                XCTFail("No ID")
                return
            }
            _ = adminID
            try await app.testing().test(
                .GET, "students/\(studentID)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: adminToken)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                })
        }
    }

    // MARK: =========================================================
    // MARK: - Forgot Password Tests
    // MARK: =========================================================

    @Test("Forgot password: enumeration-safe response for unknown email")
    func testForgotPasswordEnumerationSafe() async throws {
        try await withApp { app in
            let payload = ["email": "unknown@example.com"]
            try await app.testing().test(
                .POST, "auth/forgot-password",
                beforeRequest: { req in
                    try req.content.encode(payload)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(ForgotPasswordResponseTest.self)
                    #expect(body.success == true)
                    #expect(body.message == ForgotPasswordResponse.forgotPasswordSubmitted.message)
                })
        }
    }

    // MARK: =========================================================
    // MARK: - Health Endpoint Tests
    // MARK: =========================================================

    @Test("Health live endpoint returns ok")
    func testHealthLive() async throws {
        try await withApp { app in
            try await app.testing().test(
                .GET, "health/live",
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(HealthResponseTest.self)
                    #expect(body.status == "ok")
                })
        }
    }

    @Test("Health ready endpoint returns ready when database is available")
    func testHealthReady() async throws {
        try await withApp { app in
            try await app.testing().test(
                .GET, "health/ready",
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(HealthResponseTest.self)
                    #expect(body.status == "ready")
                })
        }
    }

    // MARK: =========================================================
    // MARK: - GraphQL Tests
    // MARK: =========================================================

    @Test("GraphQL: signupStudent mutation creates student role")
    func testGraphQLSignupStudent() async throws {
        try await withApp { app in
            let payload = GraphQLSignupStudentRequest(
                query: """
                    mutation SignupStudent($input: StudentSignupInput!) {
                      signupStudent(input: $input) {
                        id email firstName lastName role
                      }
                    }
                    """,
                variables: .init(
                    input: .init(
                        firstName: "GraphQL",
                        lastName: "User",
                        email: "gqlstudent@example.com",
                        password: "secret123",
                        confirmPassword: "secret123",
                        countryCode: "+91",
                        contactNumber: "9988776655"
                    ))
            )
            try await app.testing().test(
                .POST, "graphql",
                beforeRequest: { req in
                    try req.content.encode(payload)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    do {
                        let body = try res.content.decode(GraphQLSignupStudentResponse.self)
                        #expect(body.data?.signupStudent.email == "gqlstudent@example.com")
                        #expect(body.data?.signupStudent.role == "student")
                        #expect(body.errors?.isEmpty != false)
                    } catch {
                        XCTFail("Failed to decode GraphQL response: \(error)")
                    }
                })
        }
    }

    @Test("GraphQL: legacy signup mutation still works")
    func testGraphQLLegacySignup() async throws {
        try await withApp { app in
            let payload = GraphQLLegacySignupRequest(
                query: """
                    mutation Signup($input: StudentGraphQLCreateInput!) {
                      signup(input: $input) { id name email role }
                    }
                    """,
                variables: .init(
                    input: .init(
                        name: "Legacy User",
                        email: "legacy@example.com",
                        password: "secret123"
                    ))
            )
            try await app.testing().test(
                .POST, "graphql",
                beforeRequest: { req in
                    try req.content.encode(payload)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    do {
                        let body = try res.content.decode(GraphQLLegacySignupResponse.self)
                        #expect(body.data?.signup.email == "legacy@example.com")
                        #expect(body.data?.signup.role == "student")
                    } catch {
                        XCTFail("Failed to decode GraphQL response: \(error)")
                    }
                })
        }
    }

    @Test("GraphQL: login mutation returns role in AuthPayload")
    func testGraphQLLoginReturnsRole() async throws {
        try await withApp { app in
            _ = try await registerStudent(email: "gqllogin@example.com", on: app)

            let loginPayload = GraphQLLoginRequest(
                query: """
                    mutation Login($input: StudentGraphQLLoginInput!) {
                      login(input: $input) { token user { email role } }
                    }
                    """,
                variables: .init(input: .init(email: "gqllogin@example.com", password: "secret123"))
            )
            try await app.testing().test(
                .POST, "graphql",
                beforeRequest: { req in
                    try req.content.encode(loginPayload)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    do {
                        let body = try res.content.decode(GraphQLLoginResponse.self)
                        #expect(body.data?.login.token.isEmpty == false)
                        #expect(body.data?.login.user.role == "student")
                    } catch {
                        XCTFail("Failed to decode GraphQL login response: \(error)")
                    }
                })
        }
    }

    @Test("GraphQL: students query requires authentication")
    func testGraphQLStudentsRequiresAuth() async throws {
        try await withApp { app in
            let payload = GraphQLQueryRequest(query: "{ students { id name email } }")
            try await app.testing().test(
                .POST, "graphql",
                beforeRequest: { req in
                    try req.content.encode(payload)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(GraphQLErrorOnlyResponse.self)
                    #expect(body.errors?.isEmpty == false)
                })
        }
    }

    @Test("GraphQL: students query with student JWT returns only own record")
    func testGraphQLStudentsReturnsSelfOnly() async throws {
        try await withApp { app in
            // Create two students
            _ = try await registerStudent(
                email: "gql_a@example.com", contactNumber: "9100000001", on: app)
            _ = try await registerStudent(
                email: "gql_b@example.com", contactNumber: "9100000002", on: app)

            let token = try await login(email: "gql_a@example.com", password: "secret123", on: app)
            let payload = GraphQLQueryRequest(query: "{ students { id name email role } }")
            try await app.testing().test(
                .POST, "graphql",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                    try req.content.encode(payload)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(GraphQLStudentsResponse.self)
                    // Student should only see their own record
                    #expect(body.data?.students.count == 1)
                    #expect(body.data?.students.first?.email == "gql_a@example.com")
                })
        }
    }

    @Test("GraphQL: admin JWT returns all students")
    func testGraphQLAdminSeesAllStudents() async throws {
        try await withApp { app in
            _ = try await registerStudent(
                email: "s1@rbac.com", contactNumber: "9200000001", on: app)
            _ = try await registerStudent(
                email: "s2@rbac.com", contactNumber: "9200000002", on: app)
            _ = try await seedUser(role: "admin", email: "admin2@rbac.com", on: app.db)
            let adminToken = try await login(
                email: "admin2@rbac.com", password: "secret123", on: app)

            let payload = GraphQLQueryRequest(query: "{ students { id name email role } }")
            try await app.testing().test(
                .POST, "graphql",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: adminToken)
                    try req.content.encode(payload)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(GraphQLStudentsResponse.self)
                    // Admin sees all 3 (2 students + 1 admin)
                    #expect((body.data?.students.count ?? 0) >= 3)
                })
        }
    }

    // MARK: =========================================================
    // MARK: - Validation Utilities Tests (REST legacy path)
    // MARK: =========================================================

    @Test("REST: Empty name rejected with 400")
    func testRestSignupEmptyName() async throws {
        try await withApp { app in
            let payload = ["name": "", "email": "test@example.com", "password": "password123"]
            try await app.testing().test(
                .POST, "auth/signup",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("REST: Name exceeding max length rejected")
    func testRestSignupNameTooLong() async throws {
        try await withApp { app in
            let longName = String(repeating: "a", count: 101)
            let payload = [
                "name": longName, "email": "test@example.com", "password": "password123",
            ]
            try await app.testing().test(
                .POST, "auth/signup",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("REST: Malformed email rejected")
    func testRestSignupMalformedEmail() async throws {
        try await withApp { app in
            let payload = ["name": "TestUser", "email": "not-an-email", "password": "password123"]
            try await app.testing().test(
                .POST, "auth/signup",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("REST: Email exceeding max length rejected")
    func testRestSignupEmailTooLong() async throws {
        try await withApp { app in
            let longEmail = String(repeating: "a", count: 250) + "@example.com"
            let payload = ["name": "TestUser", "email": longEmail, "password": "password123"]
            try await app.testing().test(
                .POST, "auth/signup",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("REST: Password too short rejected")
    func testRestSignupPasswordTooShort() async throws {
        try await withApp { app in
            let payload = ["name": "TestUser", "email": "test@example.com", "password": "pass12"]
            try await app.testing().test(
                .POST, "auth/signup",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("REST: Password without numbers rejected")
    func testRestSignupPasswordNoNumbers() async throws {
        try await withApp { app in
            let payload = [
                "name": "TestUser", "email": "test@example.com", "password": "passwordonly",
            ]
            try await app.testing().test(
                .POST, "auth/signup",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("REST: Password without letters rejected")
    func testRestSignupPasswordNoLetters() async throws {
        try await withApp { app in
            let payload = ["name": "TestUser", "email": "test@example.com", "password": "12345678"]
            try await app.testing().test(
                .POST, "auth/signup",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("REST: Malformed phone number rejected")
    func testRestSignupMalformedPhoneNumber() async throws {
        try await withApp { app in
            let payload = [
                "name": "TestUser", "email": "test@example.com", "password": "password123",
                "phoneNumber": "phone#@number",
            ]
            try await app.testing().test(
                .POST, "auth/signup",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("REST: Phone number too short rejected")
    func testRestSignupPhoneNumberTooShort() async throws {
        try await withApp { app in
            let payload = [
                "name": "TestUser", "email": "test@example.com", "password": "password123",
                "phoneNumber": "12345",
            ]
            try await app.testing().test(
                .POST, "auth/signup",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("REST: Phone number too long rejected")
    func testRestSignupPhoneNumberTooLong() async throws {
        try await withApp { app in
            let longPhone = String(repeating: "1", count: 21)
            let payload = [
                "name": "TestUser", "email": "test@example.com", "password": "password123",
                "phoneNumber": longPhone,
            ]
            try await app.testing().test(
                .POST, "auth/signup",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("REST: Valid signup payload accepted")
    func testRestSignupValidPayload() async throws {
        try await withApp { app in
            let payload = [
                "name": "John Doe", "email": "john@example.com", "password": "password123",
                "phoneNumber": "+1-234-567-8900",
            ]
            try await app.testing().test(
                .POST, "auth/signup",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .ok) })
        }
    }

    @Test("REST: Valid signup with optional fields nil")
    func testRestSignupValidPayloadOptionalFieldsNil() async throws {
        try await withApp { app in
            let payload = [
                "name": "John Doe", "email": "john2@example.com", "password": "password123",
            ]
            try await app.testing().test(
                .POST, "auth/signup",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .ok) })
        }
    }

    @Test("REST: Phone number with plus prefix accepted")
    func testRestSignupPhoneWithPlus() async throws {
        try await withApp { app in
            let payload = [
                "name": "TestUser", "email": "test+plus@example.com", "password": "password123",
                "phoneNumber": "+12345678901",
            ]
            try await app.testing().test(
                .POST, "auth/signup",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .ok) })
        }
    }

    @Test("REST: Phone number with dashes accepted")
    func testRestSignupPhoneWithDashes() async throws {
        try await withApp { app in
            let payload = [
                "name": "TestUser", "email": "test+dash@example.com", "password": "password123",
                "phoneNumber": "1-234-567-8901",
            ]
            try await app.testing().test(
                .POST, "auth/signup",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .ok) })
        }
    }

    @Test("REST: Phone number with spaces accepted")
    func testRestSignupPhoneWithSpaces() async throws {
        try await withApp { app in
            let payload = [
                "name": "TestUser", "email": "test+space@example.com", "password": "password123",
                "phoneNumber": "1 234 567 8901",
            ]
            try await app.testing().test(
                .POST, "auth/signup",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .ok) })
        }
    }

    // MARK: =========================================================
    // MARK: - Password Min-Length 8 Tests (new canonical endpoint)
    // MARK: =========================================================

    @Test("Signup: exactly 7-char password rejected (boundary below min-length 8)")
    func testSignupPassword7CharsRejected() async throws {
        try await withApp { app in
            // 7 chars — one below the minimum of 8
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "pw7@example.com",
                password: "abcd123", confirmPassword: "abcd123",
                countryCode: "+91", contactNumber: "9876543210"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Signup: exactly 8-char password accepted (at min-length boundary)")
    func testSignupPassword8CharsAccepted() async throws {
        try await withApp { app in
            // Exactly 8 chars — exactly at the minimum
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "pw8@example.com",
                password: "abcd1234", confirmPassword: "abcd1234",
                countryCode: "+91", contactNumber: "9876543210"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .ok) })
        }
    }

    @Test("Signup: password with only letters (no digits) rejected")
    func testSignupNewEndpointPasswordNoDigits() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "nodig@example.com",
                password: "onlyletters", confirmPassword: "onlyletters",
                countryCode: "+91", contactNumber: "9876543210"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Signup: password with only digits (no letters) rejected")
    func testSignupNewEndpointPasswordNoLetters() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "nolet@example.com",
                password: "12345678", confirmPassword: "12345678",
                countryCode: "+91", contactNumber: "9876543210"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    // MARK: =========================================================
    // MARK: - Country Code Edge Cases
    // MARK: =========================================================

    @Test("Signup: +1 (1-digit country code) is valid")
    func testSignupCountryCodeOneDigit() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "cc1@example.com",
                password: "secret123", confirmPassword: "secret123",
                countryCode: "+1", contactNumber: "2025551234"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .ok) })
        }
    }

    @Test("Signup: +9999 (4-digit country code) is valid")
    func testSignupCountryCodeFourDigits() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "cc4@example.com",
                password: "secret123", confirmPassword: "secret123",
                countryCode: "+9999", contactNumber: "1234567"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .ok) })
        }
    }

    @Test("Signup: 5-digit country code (+12345) is rejected")
    func testSignupCountryCodeFiveDigitsRejected() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "cc5@example.com",
                password: "secret123", confirmPassword: "secret123",
                countryCode: "+12345", contactNumber: "9876543210"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Signup: country code without + prefix is rejected")
    func testSignupCountryCodeNoPlus() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "ccnoplus@example.com",
                password: "secret123", confirmPassword: "secret123",
                countryCode: "91", contactNumber: "9876543210"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Signup: country code +0 (leading zero after +) is rejected")
    func testSignupCountryCodeLeadingZero() async throws {
        try await withApp { app in
            // Leading zero is invalid — country codes start from +1
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "cc0@example.com",
                password: "secret123", confirmPassword: "secret123",
                countryCode: "+0", contactNumber: "9876543210"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    // MARK: =========================================================
    // MARK: - Contact Number Edge Cases
    // MARK: =========================================================

    @Test("Signup: exactly 7-digit contact number is valid (min boundary)")
    func testSignupContactNumber7Digits() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "cn7@example.com",
                password: "secret123", confirmPassword: "secret123",
                countryCode: "+1", contactNumber: "1234567"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .ok) })
        }
    }

    @Test("Signup: exactly 15-digit contact number is valid (max boundary)")
    func testSignupContactNumber15Digits() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "cn15@example.com",
                password: "secret123", confirmPassword: "secret123",
                countryCode: "+1", contactNumber: "123456789012345"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .ok) })
        }
    }

    @Test("Signup: 6-digit contact number rejected (below min boundary)")
    func testSignupContactNumber6DigitsRejected() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "cn6@example.com",
                password: "secret123", confirmPassword: "secret123",
                countryCode: "+91", contactNumber: "123456"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Signup: 16-digit contact number rejected (above max boundary)")
    func testSignupContactNumber16DigitsRejected() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "cn16@example.com",
                password: "secret123", confirmPassword: "secret123",
                countryCode: "+91", contactNumber: "1234567890123456"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    // MARK: =========================================================
    // MARK: - E.164 Normalization Tests
    // MARK: =========================================================

    @Test("Signup: E.164 normalization — UK +44 produces +44NNNN")
    func testSignupE164NormalizationUK() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "Jane", lastName: "Smith", email: "uk@example.com",
                password: "secret123", confirmPassword: "secret123",
                countryCode: "+44", contactNumber: "7911123456"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    do {
                        let body = try res.content.decode(StudentPublicResponse.self)
                        #expect(body.contactNumber == "+447911123456")
                    } catch {
                        XCTFail("Failed to decode response: \(error)")
                    }
                })
        }
    }

    @Test("Signup: E.164 normalization — US +1 produces +1NNNN")
    func testSignupE164NormalizationUS() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "Bob", lastName: "Jones", email: "us@example.com",
                password: "secret123", confirmPassword: "secret123",
                countryCode: "+1", contactNumber: "2025550178"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    do {
                        let body = try res.content.decode(StudentPublicResponse.self)
                        #expect(body.contactNumber == "+12025550178")
                    } catch {
                        XCTFail("Failed to decode response: \(error)")
                    }
                })
        }
    }

    // MARK: =========================================================
    // MARK: - Response Field Correctness Tests
    // MARK: =========================================================

    @Test("Signup: name field is firstName + space + lastName")
    func testSignupNameConcatenated() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "Alice", lastName: "Wonderland", email: "alice@example.com",
                password: "secret123", confirmPassword: "secret123",
                countryCode: "+91", contactNumber: "9876543210"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    do {
                        let body = try res.content.decode(StudentPublicResponse.self)
                        #expect(body.name == "Alice Wonderland")
                        #expect(body.firstName == "Alice")
                        #expect(body.lastName == "Wonderland")
                    } catch {
                        XCTFail("Failed to decode response: \(error)")
                    }
                })
        }
    }

    @Test("Signup: leading/trailing whitespace in firstName/lastName is trimmed")
    func testSignupWhitespaceTrimmed() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "  Alice  ", lastName: "  Wonderland  ", email: "alice2@example.com",
                password: "secret123", confirmPassword: "secret123",
                countryCode: "+91", contactNumber: "9876543211"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    do {
                        let body = try res.content.decode(StudentPublicResponse.self)
                        #expect(body.firstName == "Alice")
                        #expect(body.lastName == "Wonderland")
                        #expect(body.name == "Alice Wonderland")
                    } catch {
                        XCTFail("Failed to decode response: \(error)")
                    }
                })
        }
    }

    @Test("Signup: email is normalized to lowercase")
    func testSignupEmailNormalizedToLowercase() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "John", lastName: "Doe", email: "John.DOE@Example.COM",
                password: "secret123", confirmPassword: "secret123",
                countryCode: "+91", contactNumber: "9876543299"
            )
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    do {
                        let body = try res.content.decode(StudentPublicResponse.self)
                        #expect(body.email == "john.doe@example.com")
                    } catch {
                        XCTFail("Failed to decode response: \(error)")
                    }
                })
        }
    }

    @Test("Signup: new account has status=active")
    func testSignupNewAccountStatusIsActive() async throws {
        try await withApp { app in
            let payload = NewSignupPayload(
                firstName: "Status", lastName: "Test", email: "status@example.com",
                password: "secret123", confirmPassword: "secret123",
                countryCode: "+91", contactNumber: "9876543212"
            )
            // Verify the DB record directly
            try await app.testing().test(
                .POST, "auth/signup/student",
                beforeRequest: { req in
                    try req.content.encode(payload)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                })
            // Confirm student is active in DB
            let student = try await Student.query(on: app.db)
                .filter(\.$email == "status@example.com")
                .first()
            #expect(student != nil)
            #expect(student?.status == .active)
            #expect(student?.role == .student)
        }
    }

    @Test("Login: response includes user role and is student for new signups")
    func testLoginResponseIncludesRoleAndStatus() async throws {
        try await withApp { app in
            _ = try await registerStudent(
                email: "rolecheck@example.com", contactNumber: "9876599999", on: app)
            let loginPayload = ["email": "rolecheck@example.com", "password": "secret123"]
            try await app.testing().test(
                .POST, "auth/login",
                beforeRequest: { req in
                    try req.content.encode(loginPayload)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    do {
                        let body = try res.content.decode(LoginResponseTest.self)
                        #expect(body.user.role == "student")
                        #expect(!body.token.token.isEmpty)
                        // Email should be normalized in login response too
                        #expect(body.user.email == "rolecheck@example.com")
                    } catch {
                        XCTFail("Failed to decode login response: \(error)")
                    }
                })
        }
    }

    // MARK: =========================================================
    // MARK: - Reset Password Min-Length 8 Tests
    // MARK: =========================================================

    @Test("Reset password: new password of exactly 7 chars is rejected (< 8 min)")
    func testResetPasswordTooShort() async throws {
        try await withApp { app in
            // Use a fake session token — we expect 400 due to password length, not session validity
            let payload = ResetPasswordPayload(
                email: "anyone@example.com",
                sessionToken: "fake-session-token",
                newPassword: "abc1234",  // 7 chars
                confirmPassword: "abc1234"
            )
            try await app.testing().test(
                .POST, "auth/reset-password",
                beforeRequest: { req in
                    try req.content.encode(payload)
                },
                afterResponse: { res async in
                    // Expect 400 (password too short check runs before session lookup)
                    #expect(res.status == .badRequest)
                })
        }
    }

    @Test("Reset password: mismatched passwords rejected before session lookup")
    func testResetPasswordMismatch() async throws {
        try await withApp { app in
            let payload = ResetPasswordPayload(
                email: "anyone@example.com",
                sessionToken: "fake-session-token",
                newPassword: "newPass12",
                confirmPassword: "different1"
            )
            try await app.testing().test(
                .POST, "auth/reset-password",
                beforeRequest: { req in
                    try req.content.encode(payload)
                },
                afterResponse: { res async in
                    #expect(res.status == .badRequest)
                })
        }
    }

    // MARK: - TLS and Cipher Suite Tests

    @Test("TLS: Default minimum TLS version is TLS 1.2")
    func defaultMinimumTLSVersionIsTLS12() throws {
        unsetenv("TLS_MIN_VERSION")
        let version = try AppConfig.minimumTLSVersion(for: .development)
        #expect(version == .tlsv12)
    }

    @Test("TLS: Setting TLS_MIN_VERSION to 1.3 enforces TLS 1.3")
    func tlsMinVersion13EnforcesTLS13() throws {
        setenv("TLS_MIN_VERSION", "1.3", 1)
        defer { unsetenv("TLS_MIN_VERSION") }

        let version = try AppConfig.minimumTLSVersion(for: .development)
        #expect(version == .tlsv13)
    }

    @Test("TLS: Insecure TLS versions (1.0, 1.1) are rejected in production")
    func insecureTLSVersionRejectedInProduction() {
        setenv("TLS_MIN_VERSION", "1.0", 1)
        defer { unsetenv("TLS_MIN_VERSION") }

        #expect(throws: Abort.self) {
            try AppConfig.minimumTLSVersion(for: .production)
        }
    }

    @Test("TLS: Insecure TLS versions fall back safely to 1.2 in non-production")
    func insecureTLSVersionClampedInNonProduction() throws {
        setenv("TLS_MIN_VERSION", "1.1", 1)
        defer { unsetenv("TLS_MIN_VERSION") }

        let version = try AppConfig.minimumTLSVersion(for: .development)
        #expect(version == .tlsv12)
    }

    @Test("TLS: Unsupported TLS version string throws Abort error")
    func unsupportedTLSVersionThrows() {
        setenv("TLS_MIN_VERSION", "9.9", 1)
        defer { unsetenv("TLS_MIN_VERSION") }

        #expect(throws: Abort.self) {
            try AppConfig.minimumTLSVersion(for: .development)
        }
    }

    @Test("TLS: Default cipher suites contain only PFS and AEAD ciphers")
    func defaultCipherSuitesAreHardened() {
        let ciphers = AppConfig.defaultSecureCipherSuites
        let suiteList = ciphers.split(separator: ":").map(String.init)

        #expect(!suiteList.isEmpty)
        for suite in suiteList {
            // Must have forward secrecy (ECDHE)
            #expect(suite.hasPrefix("ECDHE-"))
            // Must be AEAD (GCM or Poly1305)
            #expect(suite.contains("GCM") || suite.contains("POLY1305"))
            // Must not contain CBC or obsolete algorithms
            #expect(!suite.contains("CBC"))
            #expect(!suite.contains("MD5"))
            #expect(!suite.contains("RC4"))
            #expect(!suite.contains("3DES"))
            #expect(!suite.contains("DES"))
        }
    }

    @Test("TLS: Custom cipher suites override via TLS_CIPHER_SUITES")
    func customCipherSuitesOverride() {
        let custom = "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"
        setenv("TLS_CIPHER_SUITES", custom, 1)
        defer { unsetenv("TLS_CIPHER_SUITES") }

        let active = AppConfig.tlsCipherSuites(for: .development)
        #expect(active == custom)
    }

    @Test("TLS: Database client TLS configuration enforces minimum TLS 1.2 and hardened ciphers")
    func databaseTLSConfigurationEnforcesTLS12() {
        unsetenv("DATABASE_TLS_MODE")
        let tls = databaseTLSConfiguration(for: .production)
        #expect(tls != nil)
        #expect(tls?.minimumTLSVersion == .tlsv12)
        #expect(tls?.cipherSuites == AppConfig.defaultSecureCipherSuites)
    }

    @Test("TLS: Case-insensitivity and whitespace tolerance in TLS_MIN_VERSION")
    func tlsVersionCaseInsensitiveAndWhitespaceTolerance() throws {
        setenv("TLS_MIN_VERSION", "  TLS1.2  ", 1)
        #expect(try AppConfig.minimumTLSVersion(for: .development) == .tlsv12)

        setenv("TLS_MIN_VERSION", "tlsv1.3", 1)
        #expect(try AppConfig.minimumTLSVersion(for: .development) == .tlsv13)

        unsetenv("TLS_MIN_VERSION")
    }

    @Test("TLS: Empty or whitespace TLS_CIPHER_SUITES falls back to default hardened ciphers")
    func emptyOrWhitespaceCipherSuitesFallsBack() {
        setenv("TLS_CIPHER_SUITES", "   ", 1)
        defer { unsetenv("TLS_CIPHER_SUITES") }

        let active = AppConfig.tlsCipherSuites(for: .development)
        #expect(active == AppConfig.defaultSecureCipherSuites)
    }

    @Test("TLS: Database TLS mode 'disable' returns nil configuration")
    func databaseTLSDisabledReturnsNil() {
        setenv("DATABASE_TLS_MODE", "disable", 1)
        defer { unsetenv("DATABASE_TLS_MODE") }

        let tls = databaseTLSConfiguration(for: .development)
        #expect(tls == nil)
    }

    @Test("TLS: Database TLS mode 'no-verify' still enforces TLS 1.2 and hardened ciphers")
    func databaseTLSNoVerifyEnforcesTLS12() {
        setenv("DATABASE_TLS_MODE", "no-verify", 1)
        defer { unsetenv("DATABASE_TLS_MODE") }

        let tls = databaseTLSConfiguration(for: .development)
        #expect(tls != nil)
        #expect(tls?.minimumTLSVersion == .tlsv12)
        #expect(tls?.certificateVerification == CertificateVerification.none)
        #expect(tls?.cipherSuites == AppConfig.defaultSecureCipherSuites)
    }

    @Test("TLS: Production validation fails if ENABLE_HTTPS=true but certificates are missing")
    func validateProductionSecretsFailsOnMissingCerts() {
        setenv("DATABASE_PASSWORD", "secure_prod_password_123", 1)
        setenv("ENABLE_HTTPS", "true", 1)
        setenv("TLS_CERT", "non_existent_cert_path.pem", 1)
        setenv("TLS_KEY", "non_existent_key_path.pem", 1)
        defer {
            unsetenv("DATABASE_PASSWORD")
            unsetenv("ENABLE_HTTPS")
            unsetenv("TLS_CERT")
            unsetenv("TLS_KEY")
        }

        #expect(throws: Abort.self) {
            try AppConfig.validateProductionSecrets(for: .production)
        }
    }

    // MARK: - HSTS (HTTP Strict Transport Security) Tests

    @Test("HSTS: Safe rollout default configuration provides 30-day header and disabled in non-prod")
    func hstsDefaultConfiguration() throws {
        unsetenv("HSTS_ENABLED")
        unsetenv("HSTS_MAX_AGE")
        unsetenv("HSTS_INCLUDE_SUBDOMAINS")
        unsetenv("HSTS_PRELOAD")

        // In non-production (.development, .testing), HSTS defaults to disabled to prevent accidental caching
        #expect(!AppConfig.isHSTSEnabled(for: .development))
        #expect(!AppConfig.isHSTSEnabled(for: .testing))
        #expect(try AppConfig.hstsHeaderValue(for: .development) == nil)

        // In production, HSTS defaults to enabled with safe 30-day rollout settings
        #expect(AppConfig.isHSTSEnabled(for: .production))
        #expect(try AppConfig.hstsMaxAge(for: .production) == 2_592_000)
        #expect(!AppConfig.hstsIncludeSubDomains(for: .production))
        #expect(!AppConfig.hstsPreload(for: .production))

        let prodHeader = try AppConfig.hstsHeaderValue(for: .production)
        #expect(prodHeader == "max-age=2592000")
    }

    @Test("HSTS: Custom max-age override via HSTS_MAX_AGE")
    func hstsCustomMaxAge() throws {
        setenv("HSTS_ENABLED", "true", 1)
        setenv("HSTS_MAX_AGE", "31536000", 1)
        defer {
            unsetenv("HSTS_ENABLED")
            unsetenv("HSTS_MAX_AGE")
        }

        #expect(try AppConfig.hstsMaxAge(for: .development) == 31_536_000)
        let header = try AppConfig.hstsHeaderValue(for: .development)
        #expect(header?.contains("max-age=31536000") == true)
    }

    @Test("HSTS: Negative max-age throws Abort error")
    func hstsNegativeMaxAgeThrows() {
        setenv("HSTS_MAX_AGE", "-100", 1)
        defer { unsetenv("HSTS_MAX_AGE") }

        #expect(throws: Abort.self) {
            try AppConfig.hstsMaxAge(for: .development)
        }
    }

    @Test("HSTS: Explicit opt-in for includeSubDomains and preload")
    func hstsExplicitOptInSubDomainsAndPreload() throws {
        setenv("HSTS_ENABLED", "true", 1)
        setenv("HSTS_MAX_AGE", "63072000", 1)
        setenv("HSTS_INCLUDE_SUBDOMAINS", "true", 1)
        setenv("HSTS_PRELOAD", "true", 1)
        defer {
            unsetenv("HSTS_ENABLED")
            unsetenv("HSTS_MAX_AGE")
            unsetenv("HSTS_INCLUDE_SUBDOMAINS")
            unsetenv("HSTS_PRELOAD")
        }

        #expect(AppConfig.hstsIncludeSubDomains(for: .development))
        #expect(AppConfig.hstsPreload(for: .development))

        let header = try AppConfig.hstsHeaderValue(for: .development)
        #expect(header == "max-age=63072000; includeSubDomains; preload")
    }

    @Test("HSTS: Emergency revocation with max-age=0")
    func hstsEmergencyRevocation() throws {
        setenv("HSTS_ENABLED", "true", 1)
        setenv("HSTS_MAX_AGE", "0", 1)
        defer {
            unsetenv("HSTS_ENABLED")
            unsetenv("HSTS_MAX_AGE")
        }

        let header = try AppConfig.hstsHeaderValue(for: .development)
        #expect(header == "max-age=0")
    }

    @Test("HSTS: Disabling HSTS in production suppresses header output")
    func hstsDisabledSuppressesHeader() throws {
        setenv("HSTS_ENABLED", "false", 1)
        defer { unsetenv("HSTS_ENABLED") }

        #expect(!AppConfig.isHSTSEnabled(for: .production))
        #expect(try AppConfig.hstsHeaderValue(for: .production) == nil)
    }

    @Test("HSTS: Production validation fails if HSTS_MAX_AGE is negative")
    func validateProductionSecretsFailsOnNegativeHSTSMaxAge() {
        setenv("DATABASE_PASSWORD", "secure_prod_password_123", 1)
        setenv("HSTS_MAX_AGE", "-500", 1)
        defer {
            unsetenv("DATABASE_PASSWORD")
            unsetenv("HSTS_MAX_AGE")
        }

        #expect(throws: Abort.self) {
            try AppConfig.validateProductionSecrets(for: .production)
        }
    }

    @Test("HSTS: Production validation fails if preload is enabled without includeSubDomains")
    func validateProductionSecretsFailsOnPreloadWithoutSubdomains() {
        setenv("DATABASE_PASSWORD", "secure_prod_password_123", 1)
        setenv("HSTS_PRELOAD", "true", 1)
        setenv("HSTS_INCLUDE_SUBDOMAINS", "false", 1)
        setenv("HSTS_MAX_AGE", "31536000", 1)
        defer {
            unsetenv("DATABASE_PASSWORD")
            unsetenv("HSTS_PRELOAD")
            unsetenv("HSTS_INCLUDE_SUBDOMAINS")
            unsetenv("HSTS_MAX_AGE")
        }

        #expect(throws: Abort.self) {
            try AppConfig.validateProductionSecrets(for: .production)
        }
    }

    @Test("HSTS: Production validation fails if preload is enabled with insufficient max-age")
    func validateProductionSecretsFailsOnPreloadWithLowMaxAge() {
        setenv("DATABASE_PASSWORD", "secure_prod_password_123", 1)
        setenv("HSTS_PRELOAD", "true", 1)
        setenv("HSTS_INCLUDE_SUBDOMAINS", "true", 1)
        setenv("HSTS_MAX_AGE", "86400", 1)
        defer {
            unsetenv("DATABASE_PASSWORD")
            unsetenv("HSTS_PRELOAD")
            unsetenv("HSTS_INCLUDE_SUBDOMAINS")
            unsetenv("HSTS_MAX_AGE")
        }

        #expect(throws: Abort.self) {
            try AppConfig.validateProductionSecrets(for: .production)
        }
    }

    @Test("HSTS: Production validation passes with eligible preload configuration")
    func validateProductionSecretsPassesWithValidPreloadConfig() throws {
        setenv("DATABASE_PASSWORD", "secure_prod_password_123", 1)
        setenv("HSTS_PRELOAD", "true", 1)
        setenv("HSTS_INCLUDE_SUBDOMAINS", "true", 1)
        setenv("HSTS_MAX_AGE", "31536000", 1)
        defer {
            unsetenv("DATABASE_PASSWORD")
            unsetenv("HSTS_PRELOAD")
            unsetenv("HSTS_INCLUDE_SUBDOMAINS")
            unsetenv("HSTS_MAX_AGE")
        }

        // Should not throw
        try AppConfig.validateProductionSecrets(for: .production)
    }

    @Test(
        "HSTS: Integration — HTTPS request receives safe rollout HSTS header and baseline security headers"
    )
    func hstsHeaderPresentOnHTTPSRequest() async throws {
        setenv("HSTS_ENABLED", "true", 1)
        defer { unsetenv("HSTS_ENABLED") }

        try await withApp { app in
            try await app.testing().test(
                .GET, "health/live",
                beforeRequest: { req in
                    req.headers.add(name: "X-Forwarded-Proto", value: "https")
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(res.headers.contains(name: "Strict-Transport-Security"))
                    #expect(
                        res.headers.first(name: "Strict-Transport-Security")
                            == "max-age=2592000")
                    #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
                    #expect(res.headers.first(name: "X-Frame-Options") == "DENY")
                    #expect(
                        res.headers.first(name: "Referrer-Policy")
                            == "strict-origin-when-cross-origin")
                    #expect(
                        res.headers.first(name: "Permissions-Policy")
                            == "geolocation=(), microphone=(), camera=()")
                    #expect(
                        res.headers.first(name: "Content-Security-Policy")?.contains(
                            "default-src 'self'") == true)
                    #expect(res.headers.first(name: "Vary")?.contains("X-Forwarded-Proto") == true)
                })
        }
    }

    @Test(
        "HSTS: Integration (RFC 6797 §7.2) — Plain HTTP request MUST NOT receive Strict-Transport-Security"
    )
    func hstsHeaderOmittedOnPlainHTTPRequest() async throws {
        setenv("HSTS_ENABLED", "true", 1)
        defer { unsetenv("HSTS_ENABLED") }

        try await withApp { app in
            try await app.testing().test(
                .GET, "health/live",
                beforeRequest: { req in
                    // Plain HTTP request without HTTPS scheme or X-Forwarded-Proto
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    // RFC 6797 §7.2 violation prevention: Must not send HSTS over unencrypted transport
                    #expect(!res.headers.contains(name: "Strict-Transport-Security"))
                    // Standard security headers must still be present
                    #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
                    #expect(res.headers.first(name: "X-Frame-Options") == "DENY")
                })
        }
    }

    @Test("HSTS: Integration — Omitted by default in testing environment when HSTS_ENABLED is unset")
    func hstsHeaderOmittedByDefaultInTesting() async throws {
        unsetenv("HSTS_ENABLED")

        try await withApp { app in
            try await app.testing().test(
                .GET, "health/live",
                beforeRequest: { req in
                    req.headers.add(name: "X-Forwarded-Proto", value: "https")
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(!res.headers.contains(name: "Strict-Transport-Security"))
                    #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
                })
        }
    }

    @Test("HSTS: Integration — RFC 7239 Forwarded header activates HSTS")
    func hstsHeaderWithRFC7239Forwarded() async throws {
        setenv("HSTS_ENABLED", "true", 1)
        defer { unsetenv("HSTS_ENABLED") }

        try await withApp { app in
            try await app.testing().test(
                .GET, "health/live",
                beforeRequest: { req in
                    req.headers.add(name: "Forwarded", value: "for=192.0.2.60;proto=https;by=203.0.113.43")
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(res.headers.contains(name: "Strict-Transport-Security"))
                    #expect(
                        res.headers.first(name: "Strict-Transport-Security")
                            == "max-age=2592000")
                })
        }
    }

    @Test("HSTS: Integration — Untrusted proxy headers suppressed when TRUST_PROXY_HEADERS=false")
    func hstsHeaderSuppressedWhenProxyHeadersUntrusted() async throws {
        setenv("HSTS_ENABLED", "true", 1)
        setenv("TRUST_PROXY_HEADERS", "false", 1)
        defer {
            unsetenv("HSTS_ENABLED")
            unsetenv("TRUST_PROXY_HEADERS")
        }

        try await withApp { app in
            try await app.testing().test(
                .GET, "health/live",
                beforeRequest: { req in
                    req.headers.add(name: "X-Forwarded-Proto", value: "https")
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    // Spoofed X-Forwarded-Proto must be ignored
                    #expect(!res.headers.contains(name: "Strict-Transport-Security"))
                })
        }
    }

    @Test(
        "HSTS: Integration — 404 Not Found error response over HTTPS retains HSTS and security headers"
    )
    func hstsHeaderPresentOn404ErrorResponse() async throws {
        setenv("HSTS_ENABLED", "true", 1)
        defer { unsetenv("HSTS_ENABLED") }

        try await withApp { app in
            try await app.testing().test(
                .GET, "non-existent-endpoint-path",
                beforeRequest: { req in
                    req.headers.add(name: "X-Forwarded-Proto", value: "https")
                },
                afterResponse: { res async throws in
                    #expect(res.status == .notFound)
                    #expect(res.headers.contains(name: "Strict-Transport-Security"))
                    #expect(
                        res.headers.first(name: "Strict-Transport-Security")
                            == "max-age=2592000")
                    #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
                    #expect(res.headers.first(name: "X-Frame-Options") == "DENY")
                })
        }
    }

    @Test("HSTS: Integration — 401 Unauthorized error response over HTTPS retains HSTS header")
    func hstsHeaderPresentOn401Unauthorized() async throws {
        setenv("HSTS_ENABLED", "true", 1)
        defer { unsetenv("HSTS_ENABLED") }

        try await withApp { app in
            try await app.testing().test(
                .GET, "students/\(UUID())",
                beforeRequest: { req in
                    req.headers.add(name: "X-Forwarded-Proto", value: "https")
                },
                afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                    #expect(res.headers.contains(name: "Strict-Transport-Security"))
                    #expect(
                        res.headers.first(name: "Strict-Transport-Security")
                            == "max-age=2592000")
                    #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
                })
        }
    }

    @Test("HSTS: Integration — 400 Bad Request validation error over HTTPS retains HSTS header")
    func hstsHeaderPresentOn400ValidationError() async throws {
        setenv("HSTS_ENABLED", "true", 1)
        defer { unsetenv("HSTS_ENABLED") }

        try await withApp { app in
            let malformedPayload = ["email": "not-an-email"]
            try await app.testing().test(
                .POST, "auth/login",
                beforeRequest: { req in
                    req.headers.add(name: "X-Forwarded-Proto", value: "https")
                    try req.content.encode(malformedPayload)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                    #expect(res.headers.contains(name: "Strict-Transport-Security"))
                    #expect(
                        res.headers.first(name: "Strict-Transport-Security")
                            == "max-age=2592000")
                    #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
                })
        }
    }

    @Test("HSTS: Integration — 500 Internal Server Error response over HTTPS retains HSTS header")
    func hstsHeaderPresentOn500InternalServerError() async throws {
        setenv("HSTS_ENABLED", "true", 1)
        defer { unsetenv("HSTS_ENABLED") }

        try await withApp { app in
            app.get("test-error-500") { _ -> String in
                throw Abort(.internalServerError, reason: "Simulated server failure")
            }
            try await app.testing().test(
                .GET, "test-error-500",
                beforeRequest: { req in
                    req.headers.add(name: "X-Forwarded-Proto", value: "https")
                },
                afterResponse: { res async throws in
                    #expect(res.status == .internalServerError)
                    #expect(res.headers.contains(name: "Strict-Transport-Security"))
                    #expect(
                        res.headers.first(name: "Strict-Transport-Security")
                            == "max-age=2592000")
                    #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
                    #expect(res.headers.first(name: "X-Frame-Options") == "DENY")
                })
        }
    }

    @Test("HSTS: Integration — When HSTS_ENABLED=false, HTTPS responses do not receive HSTS header")
    func hstsHeaderOmittedWhenDisabled() async throws {
        setenv("HSTS_ENABLED", "false", 1)
        defer { unsetenv("HSTS_ENABLED") }

        try await withApp { app in
            try await app.testing().test(
                .GET, "health/live",
                beforeRequest: { req in
                    req.headers.add(name: "X-Forwarded-Proto", value: "https")
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(!res.headers.contains(name: "Strict-Transport-Security"))
                    #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
                })
        }
    }

    // MARK: - Certificate Manager & Renewal Tests

    @Test("Certificate: Missing certificate file returns .missing status")
    func certificateStatusMissing() {
        let status = CertificateManager.checkCertificateStatus(
            certPath: "/non/existent/path/cert.pem",
            keyPath: "/non/existent/path/key.pem"
        )
        if case .missing(let path) = status {
            #expect(path.contains("cert.pem"))
        } else {
            #expect(Bool(false), "Expected .missing status, got \(status)")
        }
    }

    @Test("Certificate: Healthy certificate returns .valid status")
    func certificateStatusValid() {
        let status = CertificateManager.checkCertificateStatus(
            certPath: "certs/cert.pem",
            keyPath: "certs/key.pem",
            thresholdDays: 30
        )
        if case .valid(let days, _) = status {
            #expect(days > 30)
            #expect(status.isHealthy)
            #expect(!status.requiresRenewal)
        } else {
            #expect(Bool(false), "Expected .valid status for fresh cert, got \(status)")
        }
    }

    @Test("Certificate: High threshold triggers .expiringSoon status")
    func certificateStatusExpiringSoon() {
        // Since the certificate is valid for 365 days, a threshold of 400 days makes it 'expiring soon'
        let status = CertificateManager.checkCertificateStatus(
            certPath: "certs/cert.pem",
            keyPath: "certs/key.pem",
            thresholdDays: 400
        )
        if case .expiringSoon = status {
            #expect(status.requiresRenewal)
        } else {
            #expect(Bool(false), "Expected .expiringSoon status for 400-day threshold, got \(status)")
        }
    }

    @Test("Certificate: Renewal generates valid certificates, SANs, and PKCS#12 bundle")
    func certificateRenewalExecution() throws {
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let status = try CertificateManager.renewDevelopmentCertificates(
            certDir: tempDir,
            days: 365,
            thresholdDays: 30,
            force: true,
            environment: .development
        )

        #expect(status.isHealthy)

        let certFile = (tempDir as NSString).appendingPathComponent("cert.pem")
        let keyFile = (tempDir as NSString).appendingPathComponent("key.pem")
        let p12File = (tempDir as NSString).appendingPathComponent("localhost.p12")

        #expect(FileManager.default.fileExists(atPath: certFile))
        #expect(FileManager.default.fileExists(atPath: keyFile))
        #expect(FileManager.default.fileExists(atPath: p12File))

        // Verify POSIX permissions: 0600 on key and p12, 0644 on cert
        let keyAttrs = try FileManager.default.attributesOfItem(atPath: keyFile)
        let keyPerms = (keyAttrs[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        #expect(keyPerms == 0o600)

        let p12Attrs = try FileManager.default.attributesOfItem(atPath: p12File)
        let p12Perms = (p12Attrs[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        #expect(p12Perms == 0o600)

        let certAttrs = try FileManager.default.attributesOfItem(atPath: certFile)
        let certPerms = (certAttrs[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        #expect(certPerms == 0o644)
    }

    @Test("Certificate: Renewal is idempotent when certificate is already healthy")
    func certificateRenewalIdempotency() throws {
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // Initial generation
        _ = try CertificateManager.renewDevelopmentCertificates(
            certDir: tempDir,
            days: 365,
            thresholdDays: 30,
            force: true,
            environment: .development
        )

        let certFile = (tempDir as NSString).appendingPathComponent("cert.pem")
        let initialModDate = try FileManager.default.attributesOfItem(atPath: certFile)[.modificationDate] as? Date

        // Second call without force should be a no-op
        let secondStatus = try CertificateManager.renewDevelopmentCertificates(
            certDir: tempDir,
            days: 365,
            thresholdDays: 30,
            force: false,
            environment: .development
        )

        let secondModDate = try FileManager.default.attributesOfItem(atPath: certFile)[.modificationDate] as? Date
        #expect(secondStatus.isHealthy)
        #expect(initialModDate == secondModDate)
    }

    @Test("Certificate: Production safeguard strictly forbids self-signed auto-renewal")
    func certificateProductionSafeguard() {
        #expect(throws: Abort.self) {
            try CertificateManager.renewDevelopmentCertificates(
                certDir: "certs",
                force: true,
                environment: .production
            )
        }
    }

    @Test("Certificate: AppConfig auto-renewal defaults by environment")
    func appConfigCertificateSettings() {
        unsetenv("AUTO_RENEW_DEV_CERTS")
        unsetenv("DEV_CERT_RENEWAL_THRESHOLD_DAYS")

        #expect(AppConfig.autoRenewDevCerts(for: .development))
        #expect(!AppConfig.autoRenewDevCerts(for: .production))
        #expect(!AppConfig.autoRenewDevCerts(for: .testing))
        #expect(AppConfig.devCertRenewalThresholdDays(for: .development) == 30)

        setenv("AUTO_RENEW_DEV_CERTS", "false", 1)
        #expect(!AppConfig.autoRenewDevCerts(for: .development))
        unsetenv("AUTO_RENEW_DEV_CERTS")

        setenv("DEV_CERT_RENEWAL_THRESHOLD_DAYS", "45", 1)
        #expect(AppConfig.devCertRenewalThresholdDays(for: .development) == 45)
        unsetenv("DEV_CERT_RENEWAL_THRESHOLD_DAYS")
    }

    @Test("Certificate: CLI script renew-dev-certs.sh execution and check-only flag")
    func certificateCLIScriptExecution() {
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["scripts/renew-dev-certs.sh", "--cert-dir", tempDir, "--days", "365", "--threshold", "30"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try? process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        // Run check-only on newly generated valid certificates
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
        checkProcess.arguments = ["scripts/renew-dev-certs.sh", "--cert-dir", tempDir, "--check-only"]
        checkProcess.standardOutput = Pipe()
        checkProcess.standardError = Pipe()

        try? checkProcess.run()
        checkProcess.waitUntilExit()
        #expect(checkProcess.terminationStatus == 0)
    }
}

// MARK: - Test Request/Response Types

struct NewSignupPayload: Content {
    let firstName: String
    let lastName: String
    let email: String
    let password: String
    let confirmPassword: String
    let countryCode: String
    let contactNumber: String
}

struct StudentPublicResponse: Content {
    var id: UUID?
    var firstName: String?
    var lastName: String?
    var name: String
    var email: String
    var role: String
    var contactNumber: String?
    var dob: Date?
    var phoneNumber: String?
}

struct LoginResponseTest: Content {
    var user: StudentPublicResponse
    var token: TokenResponseTest
}

struct TokenResponseTest: Content {
    var token: String
}

struct LogoutResponseTest: Content {
    let message: String
}

struct HealthResponseTest: Content {
    let status: String
}

struct ForgotPasswordResponseTest: Content {
    let success: Bool
    let message: String
}

struct GraphQLQueryRequest: Content {
    let query: String
}

struct GraphQLErrorPayload: Content {
    var message: String
}

struct GraphQLErrorOnlyResponse: Content {
    let errors: [GraphQLErrorPayload]?
}

// MARK: - GraphQL Student Signup

struct GraphQLSignupStudentRequest: Content {
    let query: String
    let variables: GraphQLSignupStudentVars
}
struct GraphQLSignupStudentVars: Content {
    let input: GraphQLSignupStudentInput
}
struct GraphQLSignupStudentInput: Content {
    let firstName: String
    let lastName: String
    let email: String
    let password: String
    let confirmPassword: String
    let countryCode: String
    let contactNumber: String
}
struct GraphQLSignupStudentResponse: Content {
    var data: GraphQLSignupStudentData?
    var errors: [GraphQLErrorPayload]?
}
struct GraphQLSignupStudentData: Content {
    var signupStudent: StudentPublicResponse
}

// MARK: - GraphQL Legacy Signup

struct GraphQLLegacySignupRequest: Content {
    let query: String
    let variables: GraphQLLegacySignupVars
}
struct GraphQLLegacySignupVars: Content {
    let input: GraphQLLegacySignupInput
}
struct GraphQLLegacySignupInput: Content {
    let name: String
    let email: String
    let password: String
}
struct GraphQLLegacySignupResponse: Content {
    var data: GraphQLLegacySignupData?
    var errors: [GraphQLErrorPayload]?
}
struct GraphQLLegacySignupData: Content {
    var signup: StudentPublicResponse
}

// MARK: - GraphQL Login

struct GraphQLLoginRequest: Content {
    let query: String
    let variables: GraphQLLoginVars
}
struct GraphQLLoginVars: Content {
    let input: GraphQLLoginInput
}
struct GraphQLLoginInput: Content {
    let email: String
    let password: String
}
struct GraphQLLoginResponse: Content {
    var data: GraphQLLoginData?
    var errors: [GraphQLErrorPayload]?
}
struct GraphQLLoginData: Content {
    var login: GraphQLAuthPayload
}
struct GraphQLAuthPayload: Content {
    var token: String
    var user: StudentPublicResponse
}

// MARK: - GraphQL Students Query

struct GraphQLStudentsResponse: Content {
    let data: GraphQLStudentsData?
    let errors: [GraphQLErrorPayload]?
}
struct GraphQLStudentsData: Content {
    let students: [StudentPublicResponse]
}

// MARK: - Legacy Test Aliases (preserved for backward compat of test types)

typealias StudentPublic = StudentPublicResponse
typealias LoginResponse = LoginResponseTest
typealias TokenResponse = TokenResponseTest
typealias LogoutResponse = LogoutResponseTest
typealias HealthResponse = HealthResponseTest

// MARK: - Reset Password Test Payload

struct ResetPasswordPayload: Content {
    let email: String
    let sessionToken: String
    let newPassword: String
    let confirmPassword: String
}
