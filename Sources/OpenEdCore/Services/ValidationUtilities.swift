// MARK: - ValidationUtilities.swift
// Centralized validation logic for all domain models across REST and GraphQL.
// Ensures validation rules never drift between endpoints.
// Do NOT duplicate this logic in controllers or resolvers.

import Vapor

// MARK: - Validation Constants

struct StudentValidationConstraints {
    // Name constraints
    static let nameMinLength = 1
    static let nameMaxLength = 100

    // First/Last name constraints
    static let firstNameMinLength = 1
    static let firstNameMaxLength = 50

    static let lastNameMinLength = 1
    static let lastNameMaxLength = 50

    // Email constraints
    static let emailMaxLength = 254 // RFC 5321

    // Password constraints
    static let passwordMinLength = 8
    // Complexity: at least one letter + at least one number (product decision)

    // Date of birth constraints
    static let minAgeYears = 5
    static let maxAgeYears = 120

    // Phone number constraints (legacy combined field)
    static let phoneNumberMaxLength = 20
    static let phoneNumberMinLength = 10

    // Country code constraints (e.g. "+91", "+1", "+44")
    static let countryCodeMinLength = 2  // e.g. "+1"
    static let countryCodeMaxLength = 5  // e.g. "+9999"

    // Contact number (digits only, without country code, ITU-T E.164)
    static let contactNumberMinLength = 7
    static let contactNumberMaxLength = 15
}

// MARK: - Email Validator

struct EmailValidator {
    static func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        guard let regex = try? NSRegularExpression(pattern: emailRegex, options: []) else {
            return false
        }
        let range = NSRange(email.startIndex..<email.endIndex, in: email)
        return regex.firstMatch(in: email, options: [], range: range) != nil
    }
}

// MARK: - Phone Number Validator (Legacy Combined Field)

struct PhoneNumberValidator {
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

// MARK: - Country Code Validator

struct CountryCodeValidator {
    /// Validates a country dialing code.
    /// Must start with '+' followed by 1–4 digits. Examples: "+1", "+91", "+353", "+9999".
    static func isValidCountryCode(_ code: String) -> Bool {
        let pattern = "^\\+[1-9][0-9]{0,3}$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.firstMatch(in: code, options: [], range: range) != nil
    }
}

// MARK: - Contact Number Validator

struct ContactNumberValidator {
    /// Validates a contact number (digits only, without country code).
    /// Must be between 7 and 15 digits (ITU-T E.164 national subscriber length).
    static func isValidContactNumber(_ number: String) -> Bool {
        let digitsOnly = number.filter { $0.isNumber }
        guard digitsOnly.count == number.count else { return false } // must be purely digits
        return number.count >= StudentValidationConstraints.contactNumberMinLength &&
               number.count <= StudentValidationConstraints.contactNumberMaxLength
    }
}

// MARK: - E.164 Normalizer

enum E164 {
    /// Produces a normalized E.164 phone number by combining countryCode + contactNumber.
    /// Input: countryCode="+91", contactNumber="9876543210"
    /// Output: "+919876543210"
    ///
    /// Strips any non-digit characters from contactNumber (defensive, but validator should pass first).
    static func normalize(countryCode: String, contactNumber: String) -> String {
        let digitsOnly = contactNumber.filter { $0.isNumber }
        return countryCode + digitsOnly
    }
}

// MARK: - Password Complexity Validator

struct PasswordComplexityValidator {
    static func meetsComplexityRequirements(_ password: String) -> Bool {
        let hasLetter = password.contains { $0.isLetter }
        let hasNumber = password.contains { $0.isNumber }
        return hasLetter && hasNumber
    }
}

// MARK: - Date of Birth Validator

struct DateOfBirthValidator {
    static func isValidDateOfBirth(_ dob: Date) -> Bool {
        let now = Date()
        if dob > now { return false }
        let calendar = Calendar.current
        let ageComponents = calendar.dateComponents([.year], from: dob, to: now)
        guard let age = ageComponents.year else { return false }
        return age >= StudentValidationConstraints.minAgeYears &&
               age <= StudentValidationConstraints.maxAgeYears
    }
}

// MARK: - Validation Error Types

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
}

// MARK: - New Student Signup Validation (POST /auth/signup/student)

/// Validates a full student signup request.
/// Returns array of validation errors; empty array means all fields are valid.
///
/// - Note: `confirmPassword` is validated here but NEVER persisted.
func validateStudentSignupRequest(
    firstName: String,
    lastName: String,
    email: String,
    password: String,
    confirmPassword: String,
    countryCode: String,
    contactNumber: String
) -> [StudentValidationError] {
    var errors: [StudentValidationError] = []

    // Validate firstName
    let trimmedFirst = firstName.trimmingCharacters(in: .whitespaces)
    if trimmedFirst.isEmpty {
        errors.append(StudentValidationError(field: "firstName", message: "First name is required", code: "REQUIRED_FIELD"))
    } else if trimmedFirst.count > StudentValidationConstraints.firstNameMaxLength {
        errors.append(StudentValidationError(
            field: "firstName",
            message: "First name must not exceed \(StudentValidationConstraints.firstNameMaxLength) characters"
        ))
    }

    // Validate lastName
    let trimmedLast = lastName.trimmingCharacters(in: .whitespaces)
    if trimmedLast.isEmpty {
        errors.append(StudentValidationError(field: "lastName", message: "Last name is required", code: "REQUIRED_FIELD"))
    } else if trimmedLast.count > StudentValidationConstraints.lastNameMaxLength {
        errors.append(StudentValidationError(
            field: "lastName",
            message: "Last name must not exceed \(StudentValidationConstraints.lastNameMaxLength) characters"
        ))
    }

    // Validate email
    if email.trimmingCharacters(in: .whitespaces).isEmpty {
        errors.append(StudentValidationError(field: "email", message: "Email is required", code: "REQUIRED_FIELD"))
    } else if !EmailValidator.isValidEmail(email) {
        errors.append(StudentValidationError(field: "email", message: "Invalid email format", code: "INVALID_EMAIL"))
    } else if email.count > StudentValidationConstraints.emailMaxLength {
        errors.append(StudentValidationError(
            field: "email",
            message: "Email must not exceed \(StudentValidationConstraints.emailMaxLength) characters"
        ))
    }

    // Validate password
    if password.isEmpty {
        errors.append(StudentValidationError(field: "password", message: "Password is required", code: "REQUIRED_FIELD"))
    } else if password.count < StudentValidationConstraints.passwordMinLength {
        errors.append(StudentValidationError(
            field: "password",
            message: "Password must be at least \(StudentValidationConstraints.passwordMinLength) characters",
            code: "INVALID_PASSWORD"
        ))
    } else if !PasswordComplexityValidator.meetsComplexityRequirements(password) {
        errors.append(StudentValidationError(
            field: "password",
            message: "Password must contain at least one letter and one number",
            code: "INVALID_PASSWORD"
        ))
    }

    // Validate confirmPassword matches password (only when password is otherwise valid)
    if !password.isEmpty && password != confirmPassword {
        errors.append(StudentValidationError(
            field: "confirmPassword",
            message: "Passwords do not match",
            code: "PASSWORD_CONFIRMATION_MISMATCH"
        ))
    }

    // Validate countryCode
    if countryCode.trimmingCharacters(in: .whitespaces).isEmpty {
        errors.append(StudentValidationError(field: "countryCode", message: "Country code is required", code: "REQUIRED_FIELD"))
    } else if !CountryCodeValidator.isValidCountryCode(countryCode) {
        errors.append(StudentValidationError(
            field: "countryCode",
            message: "Country code must start with '+' followed by 1–4 digits (e.g. '+91')",
            code: "INVALID_PHONE_NUMBER"
        ))
    }

    // Validate contactNumber
    if contactNumber.trimmingCharacters(in: .whitespaces).isEmpty {
        errors.append(StudentValidationError(field: "contactNumber", message: "Contact number is required", code: "REQUIRED_FIELD"))
    } else if !ContactNumberValidator.isValidContactNumber(contactNumber) {
        errors.append(StudentValidationError(
            field: "contactNumber",
            message: "Contact number must be \(StudentValidationConstraints.contactNumberMinLength)–\(StudentValidationConstraints.contactNumberMaxLength) digits",
            code: "INVALID_PHONE_NUMBER"
        ))
    }

    return errors
}

// MARK: - Legacy Student CreateRequest Validation (Backward Compatibility)

/// Validates the legacy student create request (used by the `POST /auth/signup` alias).
func validateStudentCreateRequest(
    name: String,
    email: String,
    password: String,
    dob: Date?,
    phoneNumber: String?
) -> [StudentValidationError] {
    var errors: [StudentValidationError] = []

    if name.trimmingCharacters(in: .whitespaces).isEmpty {
        errors.append(StudentValidationError(field: "name", message: "Name cannot be empty"))
    } else if name.count > StudentValidationConstraints.nameMaxLength {
        errors.append(StudentValidationError(
            field: "name",
            message: "Name must not exceed \(StudentValidationConstraints.nameMaxLength) characters"
        ))
    }

    if email.isEmpty {
        errors.append(StudentValidationError(field: "email", message: "Email is required"))
    } else if !EmailValidator.isValidEmail(email) {
        errors.append(StudentValidationError(field: "email", message: "Email format is invalid"))
    } else if email.count > StudentValidationConstraints.emailMaxLength {
        errors.append(StudentValidationError(
            field: "email",
            message: "Email must not exceed \(StudentValidationConstraints.emailMaxLength) characters"
        ))
    }

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

    if let dob = dob {
        if !DateOfBirthValidator.isValidDateOfBirth(dob) {
            errors.append(StudentValidationError(
                field: "dob",
                message: "Date of birth must not be in the future and represent a plausible human age"
            ))
        }
    }

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

// MARK: - Student Update Validation

func validateStudentUpdateRequest(
    dob: Date?,
    name: String?,
    phoneNumber: String?
) -> [StudentValidationError] {
    var errors: [StudentValidationError] = []

    if let dob = dob, !DateOfBirthValidator.isValidDateOfBirth(dob) {
        errors.append(StudentValidationError(
            field: "dob",
            message: "Date of birth must not be in the future and represent a plausible human age"
        ))
    }

    if let name = name, !name.isEmpty, name.count > StudentValidationConstraints.nameMaxLength {
        errors.append(StudentValidationError(
            field: "name",
            message: "Name must not exceed \(StudentValidationConstraints.nameMaxLength) characters"
        ))
    }

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
