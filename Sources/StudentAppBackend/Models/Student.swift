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

    @Field(key: "dob")
    var dob: Date?

    @Field(key: "phoneNumber")
    var phoneNumber: String?

    init() {}

    init(id: UUID? = nil, name: String, email: String, passwordHash: String, dob: Date?, phoneNumber: String?) {
        self.id = id
        self.name = name
        self.email = email
        self.passwordHash    = passwordHash
        self.dob = dob
        self.phoneNumber = phoneNumber
    }

    struct Public: Content {
        var id: UUID?
        var name: String
        var email: String
        var dob: Date?
        var phoneNumber: String?
    }

    func convertToPublic() -> Public {
        return Public(id: id, name: name, email: email, dob: dob, phoneNumber: phoneNumber)
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
        let dob: Date?
        let phoneNumber: String?
    }
    
    struct UpdateRequest: Content {
        let dob: Date?
        let name: String?
        let phoneNumber: String?
    }
}

// MARK: - Validations Extension
extension Student.CreateRequest: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: !.empty && .count(1...StudentValidationConstraints.nameMaxLength))
        validations.add("email", as: String.self, is: .email && .count(...StudentValidationConstraints.emailMaxLength))
        validations.add("password", as: String.self, is: .count(StudentValidationConstraints.passwordMinLength...))
    }
}
