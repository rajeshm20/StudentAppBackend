import Fluent
import Graphiti
@preconcurrency import GraphQL
import JWTKit
import Vapor

struct GraphQLRequestBody: Content, @unchecked Sendable {
    let query: String
    let operationName: String?
    let variables: [String: Map]?

    func graphQLRequest() -> GraphQLRequest {
        GraphQLRequest(
            query: query,
            operationName: operationName,
            variables: variables ?? [:]
        )
    }
}

struct GraphQLResolver {
    func students(request: Request, arguments: NoArguments) throws -> EventLoopFuture<[Student.Public]> {
        request.eventLoop.makeFutureWithTask {
            let students = try await Student.query(on: request.db).all()
            return students.map { $0.convertToPublic() }
        }
    }

    func student(request: Request, arguments: StudentByIDArguments) throws -> EventLoopFuture<Student.Public?> {
        request.eventLoop.makeFutureWithTask {
            guard let student = try await Student.find(arguments.id, on: request.db) else {
                return nil
            }

            return student.convertToPublic()
        }
    }

    func signup(request: Request, arguments: SignupArguments) throws -> EventLoopFuture<Student.Public> {
        request.eventLoop.makeFutureWithTask {
            let create = Student.CreateRequest(
                name: arguments.input.name,
                email: arguments.input.email,
                password: arguments.input.password,
                dob: arguments.input.dob,
                phoneNumber: arguments.input.phoneNumber
            )

            let hashedPassword = try Bcrypt.hash(create.password)
            let student = Student(
                id: UUID(),
                name: create.name,
                email: create.email,
                passwordHash: hashedPassword,
                dob: create.dob,
                phoneNumber: create.phoneNumber
            )

            try await student.save(on: request.db)
            return student.convertToPublic()
        }
    }

    func login(request: Request, arguments: LoginArguments) throws -> EventLoopFuture<AuthPayload> {
        request.eventLoop.makeFutureWithTask {
            let credentials = Student.LoginRequest(
                email: arguments.input.email,
                password: arguments.input.password
            )

            guard let student = try await StudentService.shared.authenticate(credentials: credentials, on: request.db) else {
                throw Abort(.unauthorized, reason: "Invalid email or password")
            }

            let expiration = ExpirationClaim(value: Date(timeIntervalSinceNow: 60))
            let payload = StudentToken(exp: expiration, studentID: try student.requireID())
            let token = try request.jwt.sign(payload)

            return AuthPayload(user: student.convertToPublic(), token: token)
        }
    }
    struct UpdateArguments: Codable {
        let input: StudentGraphQLUpdateInput
    }

    func updateStudent(context: Request, arguments: UpdateArguments) async throws -> Student.Public {
        guard let student = try await Student.find(arguments.input.id, on: context.db) else {
            throw Abort(.notFound, reason: "Student not found")
        }

        if let dob = arguments.input.dob {
            student.dob = dob
        }

        try await student.save(on: context.db)
        return student.convertToPublic()
    }

}

struct StudentByIDArguments: Codable {
    let id: UUID
}

struct SignupArguments: Codable {
    let input: StudentGraphQLCreateInput
}

struct LoginArguments: Codable {
    let input: StudentGraphQLLoginInput
}

struct StudentGraphQLCreateInput: Codable {
    let name: String
    let email: String
    let password: String
    let dob: Date?
    let phoneNumber: String?
}

struct StudentGraphQLLoginInput: Codable {
    let email: String
    let password: String
}

struct StudentGraphQLUpdateInput: Codable {
    let id: UUID
    let dob: Date?
    let name: String?
    let phoneNumber: String?
}

struct AuthPayload: Codable {
    let user: Student.Public
    let token: String
}

final class StudentGraphQLAPI: API, @unchecked Sendable {
    typealias Resolver = GraphQLResolver
    typealias ContextType = Request

    let resolver = GraphQLResolver()
    let schema: Graphiti.Schema<GraphQLResolver, Request>

    init() throws {
        schema = try StudentGraphQLSchema.build()
    }
}

enum StudentGraphQLSchema {
    static func build() throws -> Graphiti.Schema<GraphQLResolver, Request> {
        try Graphiti.Schema<GraphQLResolver, Request> {
            Scalar(UUID.self)
            Scalar(Date.self)

            Type(Student.Public.self) {
                Field("id", at: \.id)
                Field("name", at: \.name)
                Field("email", at: \.email)
                Field("dob", at: \.dob)
                Field("phoneNumber", at: \.phoneNumber)
            }

            Type(AuthPayload.self) {
                Field("user", at: \.user)
                Field("token", at: \.token)
            }

            Input(StudentGraphQLCreateInput.self) {
                InputField("name", at: \.name)
                InputField("email", at: \.email)
                InputField("password", at: \.password)
                InputField("dob", at: \.dob)
                InputField("phoneNumber", at: \.phoneNumber)
            }

            Input(StudentGraphQLLoginInput.self) {
                InputField("email", at: \.email)
                InputField("password", at: \.password)
            }

            Input(StudentGraphQLUpdateInput.self) {
                InputField("id", at: \.id)
                InputField("dob", at: \.dob)
            }


            Query {
                Field("students", at: GraphQLResolver.students)
                Field("student", at: GraphQLResolver.student) {
                    Argument("id", at: \.id)
                }
            }

            Mutation {
                Field("signup", at: GraphQLResolver.signup) {
                    Argument("input", at: \.input)
                }
                Field("login", at: GraphQLResolver.login) {
                    Argument("input", at: \.input)
                }
                Field("updateStudent", at: GraphQLResolver.updateStudent) {
                    Argument("input", at: \.input)
                }

            }

        }
    }
}
