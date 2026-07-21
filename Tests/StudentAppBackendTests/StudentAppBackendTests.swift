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
            struct SignupPayload: Content {
                let name: String
                let email: String
                let password: String
                let dob: Date
                let phoneNumber: String
            }
            let payload = SignupPayload(
                name: "Karthick",
                email: "karthickt@example.com",
                password: "secret123",
                dob: Date(),
                phoneNumber: "1234567890"
            )
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                do {
                    let body = try res.content.decode(StudentPublic.self)
                    #expect(body.email == "karthickt@example.com")
                    #expect(body.email == "karthickt@example.com")
                    #expect(body.name == "Karthick")
                    #expect(body.phoneNumber == "1234567890")
                    #expect(body.dob != nil)
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

    @Test("Test Logout Route")
    func testLogout() async throws {
        try await withApp { app in
            let signupPayload = ["name": "Karthick", "email": "karthickt@example.com", "password": "secret123"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(signupPayload)
            })

            var token: String = ""
            let loginPayload = ["email": "karthickt@example.com", "password": "secret123"]
            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(loginPayload)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let loginResponse = try res.content.decode(LoginResponse.self)
                token = loginResponse.token.token
            })

            try await app.testing().test(.POST, "auth/logout", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let logoutResponse = try res.content.decode(LogoutResponse.self)
                #expect(logoutResponse.message == "Logout successful")
            })
        }
    }

    @Test("Test GraphQL Signup Mutation")
    func testGraphQLSignup() async throws {
        try await withApp { app in
            let payload = GraphQLSignupRequest(
                query: """
                mutation Signup($input: StudentGraphQLCreateInput!) {
                  signup(input: $input) {
                    id
                    name
                    email
                  }
                }
                """,
                variables: .init(
                    input: .init(
                        name: "Graph User",
                        email: "graphql@example.com",
                        password: "secret123"
                    )
                )
            )

            try await app.testing().test(.POST, "graphql", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                do {
                    let body = try res.content.decode(GraphQLMutationResponse<StudentPublic>.self)
                    #expect(body.data?.signup.email == "graphql@example.com")
                    #expect(body.errors?.isEmpty != false)
                } catch {
                    XCTFail("Failed to decode GraphQL response: \(error)")
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
    var dob: Date?
    var phoneNumber: String?
}

struct LoginResponse: Content {
    var user: StudentPublic
    var token: TokenResponse
}

struct TokenResponse: Content {
    var token: String
}

struct GraphQLMutationResponse<T: Content>: Content {
    var data: GraphQLMutationData<T>?
    var errors: [GraphQLErrorPayload]?
}

struct GraphQLMutationData<T: Content>: Content {
    var signup: T
}

struct GraphQLErrorPayload: Content {
    var message: String
}

struct GraphQLSignupRequest: Content {
    let query: String
    let variables: GraphQLSignupVariables
}

struct GraphQLSignupVariables: Content {
    let input: GraphQLSignupInput
}

struct GraphQLSignupInput: Content {
    let name: String
    let email: String
    let password: String
}

struct LogoutResponse: Content {
    let message: String
}
