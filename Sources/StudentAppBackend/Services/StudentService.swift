// MARK: - StudentService.swift
// Business logic for student account management.
// Controllers/resolvers delegate to this service; they do not contain business rules.
// Do NOT put authentication or password hashing directly in controllers.

import Vapor
import Fluent
import Crypto

struct StudentService {
    static let shared = StudentService()

    // MARK: - New Student Signup

    /// Creates a new student account from a StudentSignupRequest.
    ///
    /// This method:
    ///   1. Forces role = .student (ignores any client-provided role)
    ///   2. Forces status = .active
    ///   3. Normalizes the phone to E.164
    ///   4. Checks for duplicate email (application-level)
    ///   5. Checks for duplicate contactNumber (application-level)
    ///   6. Hashes the password with Bcrypt
    ///   7. Saves and returns the Student
    ///
    /// - Note: `confirmPassword` is validated upstream; it is never passed here and never persisted.
    func signupStudent(request: StudentSignupRequest, on db: any Database) async throws -> Student {
        let normalizedEmail = request.email.lowercased().trimmingCharacters(in: .whitespaces)
        let normalizedPhone = E164.normalize(countryCode: request.countryCode, contactNumber: request.contactNumber)

        // Application-level duplicate check (DB unique constraint is the final backstop)
        if try await Student.query(on: db).filter(\.$email == normalizedEmail).first() != nil {
            throw Abort(.conflict, reason: "An account with this email already exists", identifier: "EMAIL_ALREADY_EXISTS")
        }

        if try await Student.query(on: db).filter(\.$contactNumber == normalizedPhone).first() != nil {
            throw Abort(.conflict, reason: "An account with this phone number already exists", identifier: "PHONE_NUMBER_ALREADY_EXISTS")
        }

        let hashedPassword = try Bcrypt.hash(request.password)

        let student = Student(
            id: UUID(),
            firstName: request.firstName.trimmingCharacters(in: .whitespaces),
            lastName: request.lastName.trimmingCharacters(in: .whitespaces),
            name: "\(request.firstName.trimmingCharacters(in: .whitespaces)) \(request.lastName.trimmingCharacters(in: .whitespaces))",
            email: normalizedEmail,
            passwordHash: hashedPassword,
            role: .student,     // always assigned server-side
            status: .active,    // new students start active
            countryCode: request.countryCode,
            contactNumber: normalizedPhone
        )

        do {
            try await student.save(on: db)
        } catch {
            // Map DB unique constraint violations to application errors
            let errorString = "\(error)"
            if errorString.contains("Duplicate entry") || errorString.contains("UNIQUE constraint") {
                if errorString.contains("email") {
                    throw Abort(.conflict, reason: "An account with this email already exists", identifier: "EMAIL_ALREADY_EXISTS")
                } else if errorString.contains("contactNumber") {
                    throw Abort(.conflict, reason: "An account with this phone number already exists", identifier: "PHONE_NUMBER_ALREADY_EXISTS")
                }
            }
            throw error
        }

        return student
    }

    // MARK: - Legacy Signup (Backward Compatibility)

    /// Creates a student account from the legacy CreateRequest.
    /// Used by the backward-compatible `POST /auth/signup` alias.
    func create(student: Student, on db: any Database) async throws {
        student.passwordHash = try Bcrypt.hash(student.passwordHash)
        try await student.save(on: db)
    }

    // MARK: - Authentication

    /// Authenticates credentials against a stored account.
    ///
    /// Security notes:
    ///   - Returns nil for both invalid email AND invalid password (no enumeration)
    ///   - Returns nil for non-active accounts (no status leak in the error message)
    ///   - Password verification uses Bcrypt constant-time comparison
    func authenticate(credentials: Student.LoginRequest, on db: any Database) async throws -> Student? {
        let normalizedEmail = credentials.email.lowercased().trimmingCharacters(in: .whitespaces)

        guard let student = try await Student.query(on: db)
            .filter(\.$email == normalizedEmail)
            .first()
        else {
            // Return nil, not an error — prevents email enumeration
            return nil
        }

        guard try Bcrypt.verify(credentials.password, created: student.passwordHash) else {
            return nil
        }

        // Status check: only active accounts may authenticate.
        // Returns nil (same response as bad credentials) to prevent status enumeration.
        guard student.status.isLoginPermitted else {
            return nil
        }

        return student
    }
}
