@testable import StudentAppBackend
import VaporTesting
import Testing
import Fluent
import XCTest

@Suite("App Tests with DB", .serialized)
struct StudentAppBackendTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
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
    
    @Test("Test Signup Route")
    func testSignup() async throws {
        try await withApp { app in
            let payload = ["name": "Karthick", "email": "karthickt@example.com", "password": "secret123"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                do {
                    let body = try res.content.decode(StudentPublic.self)
                    #expect(body.email == "karthickt@example.com")
                    #expect(body.name == "Karthick")
                } catch {
                    XCTFail("Failed to decode LoginResponse: \(error)")
                }
            })
        }
    }

    @Test("Test Login Route")
    func testLogin() async throws {
        try await withApp { app in
            let signupPayload = ["name": "Karthick", "email": "karthickt@example.com", "password": "secret123"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(signupPayload)
            })

            let loginPayload = ["email": "karthickt@example.com", "password": "secret123"]
            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(loginPayload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                do {
                    let loginResponse = try res.content.decode(LoginResponse.self)
                    #expect(loginResponse.user.email == "karthickt@example.com")
                    #expect(!loginResponse.token.token.isEmpty)
                } catch {
                    XCTFail("Failed to decode LoginResponse: \(error)")
                }
            })
        }
    }    
}

// MARK: - Test Response Types

import Vapor

struct StudentPublic: Content {
    var id: UUID?
    var name: String
    var email: String
}

struct LoginResponse: Content {
    var user: StudentPublic
    var token: TokenResponse
}

struct TokenResponse: Content {
    var token: String
}
