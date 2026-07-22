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
                let dob: Date?
                let phoneNumber: String?
            }
            let payload = SignupPayload(
                name: "Karthick",
                email: "karthickt@example.com",
                password: "secret123",
                dob: nil,
                phoneNumber: "1234567890"
            )
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                do {
                    let body = try res.content.decode(StudentPublic.self)
                    #expect(body.email == "karthickt@example.com")
                    #expect(body.name == "Karthick")
                    #expect(body.phoneNumber == "1234567890")
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

    @Test("Test Logout Requires Authorization Header")
    func testLogoutRequiresAuth() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "auth/logout", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Test Logout Token Cannot Be Reused")
    func testLogoutRevokedToken() async throws {
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
            })

            try await app.testing().test(.POST, "auth/logout", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
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

    // MARK: - REST Validation Tests

    @Test("REST: Empty name rejected with 400")
    func testRestSignupEmptyName() async throws {
        try await withApp { app in
            let payload = ["name": "", "email": "test@example.com", "password": "password123"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("REST: Name exceeding max length rejected")
    func testRestSignupNameTooLong() async throws {
        try await withApp { app in
            let longName = String(repeating: "a", count: 101)
            let payload = ["name": longName, "email": "test@example.com", "password": "password123"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("REST: Malformed email rejected")
    func testRestSignupMalformedEmail() async throws {
        try await withApp { app in
            let payload = ["name": "TestUser", "email": "not-an-email", "password": "password123"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("REST: Email exceeding max length rejected")
    func testRestSignupEmailTooLong() async throws {
        try await withApp { app in
            let longEmail = String(repeating: "a", count: 200) + "@example.com"
            let payload = ["name": "TestUser", "email": longEmail, "password": "password123"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("REST: Password too short rejected")
    func testRestSignupPasswordTooShort() async throws {
        try await withApp { app in
            let payload = ["name": "TestUser", "email": "test@example.com", "password": "pass12"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("REST: Password without numbers rejected")
    func testRestSignupPasswordNoNumbers() async throws {
        try await withApp { app in
            let payload = ["name": "TestUser", "email": "test@example.com", "password": "passwordonly"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("REST: Password without letters rejected")
    func testRestSignupPasswordNoLetters() async throws {
        try await withApp { app in
            let payload = ["name": "TestUser", "email": "test@example.com", "password": "12345678"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("REST: Malformed phone number rejected")
    func testRestSignupMalformedPhoneNumber() async throws {
        try await withApp { app in
            let payload = ["name": "TestUser", "email": "test@example.com", "password": "password123", "phoneNumber": "phone#@number"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("REST: Phone number too short rejected")
    func testRestSignupPhoneNumberTooShort() async throws {
        try await withApp { app in
            let payload = ["name": "TestUser", "email": "test@example.com", "password": "password123", "phoneNumber": "12345"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("REST: Phone number too long rejected")
    func testRestSignupPhoneNumberTooLong() async throws {
        try await withApp { app in
            let longPhone = String(repeating: "1", count: 21)
            let payload = ["name": "TestUser", "email": "test@example.com", "password": "password123", "phoneNumber": longPhone]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("REST: Valid signup payload accepted")
    func testRestSignupValidPayload() async throws {
        try await withApp { app in
            let payload = ["name": "John Doe", "email": "john@example.com", "password": "password123", "phoneNumber": "+1-234-567-8900"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("REST: Valid signup with optional fields nil")
    func testRestSignupValidPayloadOptionalFieldsNil() async throws {
        try await withApp { app in
            let payload = ["name": "John Doe", "email": "john2@example.com", "password": "password123"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    // MARK: - Phone Number Format Tests (REST)

    @Test("REST: Phone number with plus prefix accepted")
    func testRestSignupPhoneWithPlus() async throws {
        try await withApp { app in
            let payload = ["name": "TestUser", "email": "test+plus@example.com", "password": "password123", "phoneNumber": "+12345678901"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("REST: Phone number with dashes accepted")
    func testRestSignupPhoneWithDashes() async throws {
        try await withApp { app in
            let payload = ["name": "TestUser", "email": "test+dash@example.com", "password": "password123", "phoneNumber": "1-234-567-8901"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("REST: Phone number with spaces accepted")
    func testRestSignupPhoneWithSpaces() async throws {
        try await withApp { app in
            let payload = ["name": "TestUser", "email": "test+space@example.com", "password": "password123", "phoneNumber": "1 234 567 8901"]
            try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
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
