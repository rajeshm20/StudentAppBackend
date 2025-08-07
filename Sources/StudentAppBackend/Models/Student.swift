//
//  Student.swift
//  StudentAppBackend
//
//  Created by Rajesh Mani on 07/08/25.
//


// MARK: - Student.swift
import Vapor
import Fluent

final class Student: Model, Content,  @unchecked Sendable {
    static let schema = "students"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Field(key: "email")
    var email: String

    @Field(key: "passwordHash")
    var passwordHash: String

    init() {}

    init(id: UUID? = nil, name: String, email: String, passwordHash: String) {
        self.id = id
        self.name = name
        self.email = email
        self.passwordHash = passwordHash
    }

    struct Public: Content {
        var id: UUID?
        var name: String
        var email: String
    }

    func convertToPublic() -> Public {
        return Public(id: id, name: name, email: email)
    }

    struct LoginRequest: Content {
        let email: String
        let password: String
    }
}


extension Student {
    struct CreateRequest: Content {
        let name: String
        let email: String
        let password: String
    }
}
