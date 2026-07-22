//
//  ValidationUtilities.swift
//  StudentAppBackend
//
//  Created by Security Hardening
//
//  Shared validation logic for Student domain model across REST and GraphQL layers.
//  Ensures validation rules don't drift between endpoints.

import Vapor

// MARK: - Validation Constants
struct StudentValidationConstraints {
    // Name constraints
    static let nameMinLength = 1
    static let nameMaxLength = 100
    
    // Email constraints
    static let emailMaxLength = 254 // RFC 5321
    
    // Password constraints
    static let passwordMinLength = 8
    // NOTE: Password complexity (mix of letters/numbers) is flagged as a PRODUCT DECISION.
    // Currently enforcing: minimum length + at least one letter + at least one number.
    // Adjust or remove complexity check based on product requirements.
    
    // Date of birth constraints
    static let minAgeYears = 5      // Minimum plausible age
    static let maxAgeYears = 120    // Maximum plausible age
    
    // Phone number constraints
    static let phoneNumberMaxLength = 20
    static let phoneNumberMinLength = 10
}

// MARK: - Email Validator Helper
struct EmailValidator {
    /// Validates email format using a simple regex pattern.
    /// Vapor's .email validator uses a similar pattern internally.
    static func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        guard let regex = try? NSRegularExpression(pattern: emailRegex, options: []) else {
            return false
        }
        let range = NSRange(email.startIndex..<email.endIndex, in: email)
        return regex.firstMatch(in: email, options: [], range: range) != nil
    }
}

// MARK: - Phone Number Validator Helper
struct PhoneNumberValidator {
    /// Validates phone number format: digits, +, -, spaces only.
    /// Must be between minLength and maxLength.
    /// Examples: "+1-234-567-8900", "2345678900", "+1 234 567 8900"
    static func isValidPhoneNumber(_ phone: String) -> Bool {
        let phoneRegex = "^[+]?[0-9\\s\\-]+$"
        guard let regex = try? NSRegularExpression(pattern: phoneRegex, options: []) else {
            return false
        }
        let range = NSRange(phone.startIndex..<phone.endIndex, in: phone)
        let isValidFormat = regex.firstMatch(in: phone, options: [], range: range) != nil
        
        return isValidFormat &&
               phone.count >= StudentValidationConstraints.phoneNumberMinLength &&
               phone.count <= StudentValidationConstraints.phoneNumberMaxLength
    }
}

// MARK: - Password Complexity Helper
struct PasswordComplexityValidator {
    /// Checks if password meets minimum complexity: at least one letter AND one number.
    /// This is a PRODUCT DECISION — adjust the requirements as needed.
    static func meetsComplexityRequirements(_ password: String) -> Bool {
        let hasLetter = password.contains { $0.isLetter }
        let hasNumber = password.contains { $0.isNumber }
        return hasLetter && hasNumber
    }
}

// MARK: - Date of Birth Validator Helper
struct DateOfBirthValidator {
    /// Validates that DOB is:
    /// 1. Not in the future
    /// 2. Represents a plausible human age (between minAgeYears and maxAgeYears)
    static func isValidDateOfBirth(_ dob: Date) -> Bool {
        let now = Date()
        
        // Must not be in the future
        if dob > now {
            return false
        }
        
        let calendar = Calendar.current
        let ageComponents = calendar.dateComponents([.year], from: dob, to: now)
        guard let age = ageComponents.year else {
            return false
        }
        
        // Check age is within plausible range
        return age >= StudentValidationConstraints.minAgeYears &&
               age <= StudentValidationConstraints.maxAgeYears
    }
}

// MARK: - Validation Error Struct
struct StudentValidationError: Error, Content, Codable {
    let field: String
    let message: String
    let code: String
    
    init(field: String, message: String, code: String = "VALIDATION_ERROR") {
        self.field = field
        self.message = message
        self.code = code
    }
}

struct ValidationErrorResponse: Content {
    let errors: [StudentValidationError]
    
    init(errors: [StudentValidationError]) {
        self.errors = errors
    }
}

// MARK: - Student CreateRequest Validation Logic
/// This function centralizes validation for Student creation across REST and GraphQL.
/// Returns an array of validation errors; empty array means valid.
func validateStudentCreateRequest(
    name: String,
    email: String,
    password: String,
    dob: Date?,
    phoneNumber: String?
) -> [StudentValidationError] {
    var errors: [StudentValidationError] = []
    
    // Validate name
    if name.trimmingCharacters(in: .whitespaces).isEmpty {
        errors.append(StudentValidationError(
            field: "name",
            message: "Name cannot be empty"
        ))
    } else if name.count > StudentValidationConstraints.nameMaxLength {
        errors.append(StudentValidationError(
            field: "name",
            message: "Name must not exceed \(StudentValidationConstraints.nameMaxLength) characters"
        ))
    }
    
    // Validate email
    if email.isEmpty {
        errors.append(StudentValidationError(
            field: "email",
            message: "Email is required"
        ))
    } else if !EmailValidator.isValidEmail(email) {
        errors.append(StudentValidationError(
            field: "email",
            message: "Email format is invalid"
        ))
    } else if email.count > StudentValidationConstraints.emailMaxLength {
        errors.append(StudentValidationError(
            field: "email",
            message: "Email must not exceed \(StudentValidationConstraints.emailMaxLength) characters"
        ))
    }
    
    // Validate password
    if password.count < StudentValidationConstraints.passwordMinLength {
        errors.append(StudentValidationError(
            field: "password",
            message: "Password must be at least \(StudentValidationConstraints.passwordMinLength) characters"
        ))
    } else if !PasswordComplexityValidator.meetsComplexityRequirements(password) {
        errors.append(StudentValidationError(
            field: "password",
            message: "Password must contain at least one letter and one number"
        ))
    }
    
    // Validate date of birth (optional)
    if let dob = dob {
        if !DateOfBirthValidator.isValidDateOfBirth(dob) {
            errors.append(StudentValidationError(
                field: "dob",
                message: "Date of birth must not be in the future and represent a plausible human age"
            ))
        }
    }
    
    // Validate phone number (optional)
    if let phone = phoneNumber, !phone.isEmpty {
        if !PhoneNumberValidator.isValidPhoneNumber(phone) {
            errors.append(StudentValidationError(
                field: "phoneNumber",
                message: "Phone number must be \(StudentValidationConstraints.phoneNumberMinLength)-\(StudentValidationConstraints.phoneNumberMaxLength) characters and contain only digits, +, -, or spaces"
            ))
        }
    }
    
    return errors
}

/// Validates Student update request (used in GraphQL mutations).
/// Returns an array of validation errors; empty array means valid.
func validateStudentUpdateRequest(
    dob: Date?,
    name: String?,
    phoneNumber: String?
) -> [StudentValidationError] {
    var errors: [StudentValidationError] = []
    
    // Validate date of birth (optional)
    if let dob = dob {
        if !DateOfBirthValidator.isValidDateOfBirth(dob) {
            errors.append(StudentValidationError(
                field: "dob",
                message: "Date of birth must not be in the future and represent a plausible human age"
            ))
        }
    }
    
    // Validate name (optional)
    if let name = name, !name.isEmpty {
        if name.count > StudentValidationConstraints.nameMaxLength {
            errors.append(StudentValidationError(
                field: "name",
                message: "Name must not exceed \(StudentValidationConstraints.nameMaxLength) characters"
            ))
        }
    }
    
    // Validate phone number (optional)
    if let phone = phoneNumber, !phone.isEmpty {
        if !PhoneNumberValidator.isValidPhoneNumber(phone) {
            errors.append(StudentValidationError(
                field: "phoneNumber",
                message: "Phone number must be \(StudentValidationConstraints.phoneNumberMinLength)-\(StudentValidationConstraints.phoneNumberMaxLength) characters and contain only digits, +, -, or spaces"
            ))
        }
    }
    
    return errors
}
