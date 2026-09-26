// MARK: - Student.swift
// Core domain model for all user accounts.
// A single Student record represents any user regardless of role
// (ADMIN, PRINCIPAL, TEACHER, or STUDENT).
// The `role` field is always assigned server-side; clients cannot influence it.

import Vapor
import Fluent

final class Student: Model, Content, @unchecked Sendable {
    static let schema = "students"

    // MARK: - Persistent Fields

    @ID(key: .id)
    var id: UUID?

    /// Legacy single-name field. Kept for backward compatibility.
    /// New signups should use `firstName` + `lastName` instead.
    @Field(key: "name")
    var name: String

    @Field(key: "email")
    var email: String

    @Field(key: "passwordHash")
    var passwordHash: String

    @Field(key: "dob")
    var dob: Date?

    /// Legacy combined phone field. Kept for backward compatibility.
    @Field(key: "phoneNumber")
    var phoneNumber: String?

    // MARK: - Extended Fields (added via AddRoleStatusPhoneToStudents migration)

    /// Authorization role. Always assigned server-side; never trusted from client input.
    /// Stored as Optional in DB (SQLite ALTER TABLE limitation); defaults to .student if NULL (legacy rows).
    @OptionalField(key: "role")
    var _role: UserRole?

    /// Non-optional accessor — new code should always use this.
    var role: UserRole {
        get { _role ?? .student }
        set { _role = newValue }
    }

    /// Account lifecycle status. Only `.active` accounts can authenticate.
    /// Stored as Optional in DB (SQLite ALTER TABLE limitation); defaults to .active if NULL (legacy rows).
    @OptionalField(key: "status")
    var _status: AccountStatus?

    /// Non-optional accessor — new code should always use this.
    var status: AccountStatus {
        get { _status ?? .active }
        set { _status = newValue }
    }

    @Field(key: "firstName")
    var firstName: String?

    @Field(key: "lastName")
    var lastName: String?

    /// Country dialing code, e.g. "+91".
    @Field(key: "countryCode")
    var countryCode: String?

    /// Normalized E.164 phone number (countryCode + number), e.g. "+919876543210".
    /// Stored normalized; unique constraint enforced at DB level.
    @Field(key: "contactNumber")
    var contactNumber: String?

    // MARK: - Timestamps

    @Timestamp(key: "createdAt", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updatedAt", on: .update)
    var updatedAt: Date?

    // MARK: - Initializers

    init() {}

    /// Full initializer — used by signup service.
    init(
        id: UUID? = nil,
        firstName: String?,
        lastName: String?,
        name: String,
        email: String,
        passwordHash: String,
        role: UserRole,
        status: AccountStatus,
        dob: Date? = nil,
        phoneNumber: String? = nil,
        countryCode: String? = nil,
        contactNumber: String? = nil
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.name = name
        self.email = email
        self.passwordHash = passwordHash
        self.role = role
        self.status = status
        self.dob = dob
        self.phoneNumber = phoneNumber
        self.countryCode = countryCode
        self.contactNumber = contactNumber
    }

    // MARK: - Public Response Types

    /// Safe public representation — never includes passwordHash, confirmPassword, or internal fields.
    struct Public: Content {
        var id: UUID?
        var firstName: String?
        var lastName: String?
        var name: String
        var email: String
        var role: UserRole
        var status: AccountStatus
        var dob: Date?
        var phoneNumber: String?
        var contactNumber: String?
        var countryCode: String?
    }

    func convertToPublic() -> Public {
        return Public(
            id: id,
            firstName: firstName,
            lastName: lastName,
            name: name,
            email: email,
            role: role,
            status: status,
            dob: dob,
            phoneNumber: phoneNumber,
            contactNumber: contactNumber,
            countryCode: countryCode
        )
    }

    // MARK: - Login Request DTO

    struct LoginRequest: Content {
        let email: String
        let password: String
    }
}

// MARK: - Student Signup Request DTO (New Canonical Signup)

/// Request body for POST /auth/signup/student
/// The server assigns role=student automatically; no role field accepted from client.
struct StudentSignupRequest: Content {
    let firstName: String
    let lastName: String
    let email: String
    let password: String
    let confirmPassword: String
    let countryCode: String
    let contactNumber: String
}

// MARK: - Legacy Create/Update Request DTOs (Backward Compatibility)

extension Student {
    /// Legacy signup request — kept so existing `POST /auth/signup` clients continue to work.
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

// MARK: - Vapor Validations (Legacy CreateRequest)

extension Student.CreateRequest: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: !.empty && .count(1...StudentValidationConstraints.nameMaxLength))
        validations.add("email", as: String.self, is: .email && .count(...StudentValidationConstraints.emailMaxLength))
        validations.add("password", as: String.self, is: .count(StudentValidationConstraints.passwordMinLength...))
    }
}
