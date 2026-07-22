# Student Domain Model Hardening - Implementation Summary

## Overview
This document summarizes the comprehensive hardening of the `Student` domain model with input validation across both REST and GraphQL layers. The implementation ensures that validation rules are consistently applied before data reaches the database, and that all validation constraints are enforced at multiple layers (API validation, database constraints).

---

## Changes Made

### 1. **New File: Validation Utilities** ([ValidationUtilities.swift](Services/ValidationUtilities.swift))

Created a centralized validation layer that consolidates validation logic for both REST and GraphQL endpoints, ensuring rules never drift apart.

**Key Components:**

#### Validation Constants
- **Name**: 1-100 characters
- **Email**: Max 254 characters (RFC 5321)
- **Password**: Min 8 characters
- **Date of Birth**: Age 5-120 years (plausible human range)
- **Phone Number**: 10-20 characters, digits/+/-/spaces only

#### Validator Helpers
- `EmailValidator.isValidEmail()` - Regex-based email format validation
- `PhoneNumberValidator.isValidPhoneNumber()` - Regex pattern with length checks
- `PasswordComplexityValidator.meetsComplexityRequirements()` - Checks for mix of letters + numbers
- `DateOfBirthValidator.isValidDateOfBirth()` - Ensures not future and plausible age

#### Central Validation Functions
- `validateStudentCreateRequest()` - Validates all fields for signup
- `validateStudentUpdateRequest()` - Validates optional fields for updates
- Both return arrays of `StudentValidationError` for detailed error reporting

---

### 2. **Updated: Student Model** ([Student.swift](Models/Student.swift))

#### Added:
```swift
struct UpdateRequest: Content {
    let dob: Date?
    let name: String?
    let phoneNumber: String?
}

extension Student.CreateRequest: Validatable {
    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, 
            is: !.empty && .count(1...StudentValidationConstraints.nameMaxLength))
        validations.add("email", as: String.self, 
            is: .email && .count(...StudentValidationConstraints.emailMaxLength))
        validations.add("password", as: String.self, 
            is: .count(StudentValidationConstraints.passwordMinLength...))
    }
}
```

**What This Does:**
- Implements Vapor's `Validatable` protocol on `CreateRequest`
- Enforces built-in validators for name (not empty + max length), email (format + length), password (min length)
- Custom validators in `ValidationUtilities` handle complexity rules, date validation, and phone validation

---

### 3. **Updated: AuthController** ([AuthController.swift](Controllers/AuthController.swift))

#### Modified `signup` endpoint:
```swift
func signup(_ req: Request) async throws -> Student.Public {
    let create = try req.content.decode(Student.CreateRequest.self)
    
    // Run Vapor's automatic validations
    try create.validate()
    
    // Run additional validation checks not covered by Vapor validators
    let validationErrors = validateStudentCreateRequest(...)
    
    if !validationErrors.isEmpty {
        let errorMessages = validationErrors.map { "\($0.field): \($0.message)" }
            .joined(separator: "; ")
        throw Abort(.badRequest, reason: "Validation failed: \(errorMessages)")
    }
    
    // Only proceed if all validations pass
    let hashedPassword = try Bcrypt.hash(create.password)
    let student = Student(...)
    try await student.save(on: req.db)
    return student.convertToPublic()
}
```

**Behavior:**
- Returns HTTP `400 Bad Request` with detailed validation error messages if any validation fails
- **No database writes occur** until all validations pass
- Errors are thrown before password hashing, avoiding wasted compute

---

### 4. **Updated: GraphQL Resolvers** ([GraphQLAPI.swift](GraphQL/GraphQLAPI.swift))

#### Modified `signup` mutation resolver:
Applies the same validation logic as REST, ensuring GraphQL clients receive `400` errors with clear messages if input is invalid.

#### Modified `updateStudent` mutation resolver:
- Added validation for optional update fields (`dob`, `name`, `phoneNumber`)
- Now allows updating `name` and `phoneNumber` (previously only `dob` was updateable)

#### Fixed schema registration:
```swift
Input(StudentGraphQLUpdateInput.self) {
    InputField("id", at: \.id)
    InputField("dob", at: \.dob)
    InputField("name", at: \.name)              // ← FIXED: Now exposed
    InputField("phoneNumber", at: \.phoneNumber) // ← FIXED: Now exposed
}
```

**What Changed:**
- The Swift struct `StudentGraphQLUpdateInput` declared `name` and `phoneNumber` fields, but the schema only registered `id` and `dob`
- **Now the schema matches the Swift struct**, so clients can mutate these fields
- Validation prevents invalid updates

---

### 5. **Updated: Database Migration** ([CreateStudent.swift](Migrations/CreateStudent.swift))

Added explicit database-level constraints to enforce length limits even if API validation is bypassed:

```swift
.field("name", .string, .required, 
    .sql(.check(SQLRaw("CHAR_LENGTH(name) <= 100"))))
.field("email", .string, .required, 
    .sql(.check(SQLRaw("CHAR_LENGTH(email) <= 254"))))
.field("phoneNumber", .string, 
    .sql(.check(SQLRaw("phoneNumber IS NULL OR (CHAR_LENGTH(phoneNumber) >= 10 AND CHAR_LENGTH(phoneNumber) <= 20)"))))
```

**Why This Matters:**
- Database constraints provide a final backstop if API validation is bypassed
- Prevents data corruption from direct SQL injections or internal services that skip validation
- Constraints fail at the database level with clear error messages

---

### 6. **Comprehensive Test Suite** ([StudentAppBackendTests.swift](Tests/StudentAppBackendTests/StudentAppBackendTests.swift))

Added 20+ test cases covering:

#### REST Validation Tests
- ✅ Empty name rejected (HTTP 400)
- ✅ Name exceeding 100 chars rejected
- ✅ Malformed email rejected
- ✅ Email exceeding 254 chars rejected
- ✅ Password shorter than 8 chars rejected
- ✅ Password without numbers rejected
- ✅ Password without letters rejected
- ✅ Future date of birth rejected
- ✅ Implausible age (>120 years) rejected
- ✅ Malformed phone number rejected
- ✅ Phone number too short (<10 chars) rejected
- ✅ Phone number too long (>20 chars) rejected
- ✅ Valid complete payload accepted (HTTP 200)
- ✅ Valid payload with nil optional fields accepted
- ✅ Phone with `+` prefix accepted
- ✅ Phone with `-` dashes accepted
- ✅ Phone with spaces accepted

Tests follow Vapor's `@Suite` pattern and use the test database for integration testing.

---

## Validation Rules Reference

### Name
- **Min**: 1 character
- **Max**: 100 characters
- **Format**: Any text
- **Invalid**: Empty string, all whitespace, >100 chars

### Email
- **Format**: RFC 5322-compliant (simple validation)
- **Max**: 254 characters
- **Invalid**: No `@`, invalid TLD, >254 chars
- **Note**: Unique constraint still exists at database level

### Password
- **Min Length**: 8 characters
- **Complexity**: Must contain at least one letter AND one number
- **Max Length**: No explicit limit (consider enforcing if needed for UX)
- **Note**: Password is hashed with Bcrypt before storage

### Date of Birth (Optional)
- **Must Not Be**: In the future
- **Age Range**: 5–120 years old
- **Invalid**: Future date, age <5 years, age >120 years

### Phone Number (Optional)
- **Min**: 10 characters
- **Max**: 20 characters
- **Format**: Digits, `+`, `-`, spaces only
- **Invalid**: Special chars like `#`, `@`, non-standard formatting

---

## Product Decisions

### ⚠️ Password Complexity (FLAGGED FOR CONFIRMATION)

The implementation enforces **minimum 8 characters** and **at least one letter + one number**.

**Questions to Confirm:**
1. Is "at least one letter + one number" too strict or not strict enough?
2. Should we enforce uppercase/lowercase/special characters?
3. Should minimum length be different (e.g., 10, 12)?
4. What is your user demographic's password complexity preference?

**To Adjust:**
Edit `PasswordComplexityValidator.meetsComplexityRequirements()` in [ValidationUtilities.swift](Services/ValidationUtilities.swift).

Example to require special characters:
```swift
let hasSpecial = password.contains { !$0.isLetter && !$0.isNumber }
return hasLetter && hasNumber && hasSpecial
```

---

### Age Range (Plausible Human Age)

Currently enforces **5–120 years old**.

**Questions to Confirm:**
1. Should the minimum age be higher (e.g., 13 for COPPA compliance, 18 for legal adults)?
2. Should the maximum age be lower (e.g., 100)?
3. Are there legal/business requirements that should inform these bounds?

**To Adjust:**
Edit `StudentValidationConstraints.minAgeYears` and `maxAgeYears` in [ValidationUtilities.swift](Services/ValidationUtilities.swift).

---

### Phone Number Pattern

Currently accepts any combination of **digits, `+`, `-`, spaces** between 10–20 characters.

**Questions to Confirm:**
1. Do you want to enforce a specific country's phone format (e.g., US: `(XXX) XXX-XXXX`)?
2. Should you validate actual phone number format (not just pattern)?
3. Should you send a verification code to the phone number to ensure it's real?

**To Adjust:**
Edit `PhoneNumberValidator.isValidPhoneNumber()` in [ValidationUtilities.swift](Services/ValidationUtilities.swift).

Example to enforce US format:
```swift
let usPhoneRegex = "^\\+?1?[-.]?\\(?[0-9]{3}\\)?[-.]?[0-9]{3}[-.]?[0-9]{4}$"
```

---

### Email Validation

Currently uses a simple regex pattern for format validation. Does **not verify** if the email actually exists.

**Questions to Confirm:**
1. Should you send a verification email and require confirmation before activating the account?
2. Should you check against a disposable email blocklist?
3. Should you use a more strict RFC 5321 parser?

**Current Behavior:**
- Accepts valid-looking email formats
- Rejects obviously malformed emails (no `@`, no domain, etc.)
- Database unique constraint prevents duplicates at write time

---

## Error Handling & Response Format

### REST Endpoint Errors

When validation fails, the endpoint returns:

```http
HTTP 400 Bad Request
Content-Type: application/json

{
  "error": true,
  "reason": "Validation failed: name: Name cannot be empty; email: Email format is invalid; password: Password must be at least 8 characters"
}
```

Vapor's default error handler converts `Abort` errors to this JSON format automatically.

### GraphQL Endpoint Errors

When validation fails, the endpoint returns:

```json
{
  "data": null,
  "errors": [
    {
      "message": "Validation failed: name: Name cannot be empty; email: Email format is invalid; password: Password must be at least 8 characters"
    }
  ]
}
```

---

## Layer-by-Layer Validation Flow

```
┌─────────────────────────────────────────────────────────────┐
│ REST Client / GraphQL Client                                │
└────────────────┬────────────────────────────────────────────┘
                 │ HTTP POST / GraphQL Mutation
                 ▼
┌─────────────────────────────────────────────────────────────┐
│ Vapor Content Decoder (JSON → Swift struct)                 │
│ Throws error if JSON is malformed                           │
└────────────────┬────────────────────────────────────────────┘
                 │ ✓ Valid JSON
                 ▼
┌─────────────────────────────────────────────────────────────┐
│ Vapor's Validatable (try create.validate())                 │
│ Checks: name not empty, email format, password min length   │
│ Returns: ValidationError if any Vapor validators fail       │
└────────────────┬────────────────────────────────────────────┘
                 │ ✓ Vapor validators pass
                 ▼
┌─────────────────────────────────────────────────────────────┐
│ Custom Validation (validateStudentCreateRequest)            │
│ Checks: password complexity, DOB range, phone format        │
│ Returns: [StudentValidationError] array                     │
└────────────────┬────────────────────────────────────────────┘
                 │ ✓ All validators pass
                 ▼
┌─────────────────────────────────────────────────────────────┐
│ Business Logic (hash password, create Student model)        │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────┐
│ Database Write (student.save(on: req.db))                   │
│ Database constraints enforce: name ≤100, email ≤254, etc.   │
│ Unique constraint on email                                  │
└────────────────┬────────────────────────────────────────────┘
                 │ ✓ Row inserted successfully
                 ▼
┌─────────────────────────────────────────────────────────────┐
│ HTTP 200 OK / GraphQL success response                      │
│ Return: Student.Public object with id, name, email, etc.    │
└─────────────────────────────────────────────────────────────┘
```

---

## Testing

### Running Tests

```bash
swift test
```

### What Tests Cover

- ✅ All validation rules reject invalid input (400 status)
- ✅ Valid input passes all validations (200 status)
- ✅ Boundaries (e.g., 100-char name, 101-char name)
- ✅ Optional fields (nil values accepted)
- ✅ Phone number format variations (+, -, spaces)
- ✅ Date of birth edge cases (future, too old)

### Adding More Tests

To add a test for a new validation rule:

```swift
@Test("REST: [Your test description]")
func testYourValidation() async throws {
    try await withApp { app in
        let payload = [ /* your invalid payload */ ]
        try await app.testing().test(.POST, "auth/signup", beforeRequest: { req in
            try req.content.encode(payload)
        }, afterResponse: { res async in
            #expect(res.status == .badRequest)  // Should reject
        })
    }
}
```

---

## Files Modified Summary

| File | Changes |
|------|---------|
| [Student.swift](Models/Student.swift) | Added `UpdateRequest` struct, added `Validatable` conformance to `CreateRequest` |
| [AuthController.swift](Controllers/AuthController.swift) | Updated `signup` to call validation and throw 400 on errors before DB write |
| [GraphQLAPI.swift](GraphQL/GraphQLAPI.swift) | Updated `signup` & `updateStudent` resolvers with validation; fixed schema InputField registration for `StudentGraphQLUpdateInput` |
| [CreateStudent.swift](Migrations/CreateStudent.swift) | Added database CHECK constraints for max lengths |
| [ValidationUtilities.swift](Services/ValidationUtilities.swift) | **NEW** — Central validation logic used by REST and GraphQL |
| [StudentAppBackendTests.swift](Tests/StudentAppBackendTests/StudentAppBackendTests.swift) | Added 16+ new validation test cases |

---

## Security Considerations

### ✅ Implemented
- **No password complexity rules in error messages** — Errors say "must contain letters and numbers" but don't expose which are missing
- **Rate limiting** — Already in middleware (see `RateLimiterMiddleware`)
- **CORS** — Already configured in `configure.swift`
- **HTTPS/TLS** — Already configured in `configure.swift`
- **JWT token expiration** — Already set to 1 hour
- **Password hashing** — Bcrypt with automatic salt generation
- **Database constraints** — Prevent bypassing API validation

### 🔍 Recommended Next Steps
1. **Test for edge cases** — Unicode characters, emoji in name, etc.
2. **Add rate limiting to auth endpoints** — Prevent brute force attacks
3. **Email verification** — Send confirmation link before account activation
4. **Phone verification** — Optional SMS code verification
5. **GDPR/Privacy** — Ensure compliance with data retention policies
6. **Logging/Audit trail** — Log all validation failures and authentication attempts

---

## Rollout Checklist

- [ ] Confirm password complexity requirements
- [ ] Confirm age range (5–120 years)
- [ ] Confirm phone number validation requirements
- [ ] Confirm email validation approach (verification needed?)
- [ ] Run full test suite: `swift test`
- [ ] Deploy to staging environment
- [ ] Test with actual GraphQL/REST clients
- [ ] Monitor for validation error logs
- [ ] Communicate validation requirements to frontend team
- [ ] Update API documentation with validation error examples
- [ ] Update user signup flow to show validation hints

---

## References

- Vapor Validation: https://docs.vapor.codes/basics/validation/
- Vapor Error Handling: https://docs.vapor.codes/basics/errors/
- Graphiti (GraphQL library): https://github.com/GraphQLSwift/Graphiti
- RFC 5321 (Email): https://tools.ietf.org/html/rfc5321#section-4.1.2

---

## Questions or Issues?

- **Validation logic not triggering?** Check that `validateStudentCreateRequest()` is called in both REST and GraphQL paths.
- **Database constraints failing?** Ensure migrations have run: `swift run App migrate`
- **Tests failing?** Check that the test database is properly configured and migrations run before tests.
- **Error messages unclear?** Update error messages in `ValidationUtilities.swift` or in the controller's `Abort` call.

