import Fluent
import Foundation
import SQLKit
import Vapor

public enum OTPVerificationOutcome: Sendable, Equatable {
    case success(sessionToken: String)
    case invalidOrExpiredCode
    case invalidCode(remainingAttempts: Int)
    case tooManyAttempts
    case expired
}

protocol PasswordResetRepository: Sendable {
    func create(_ token: PasswordResetToken, on db: any Database) async throws
    func update(_ token: PasswordResetToken, on db: any Database) async throws
    func invalidateAll(forEmail email: String, on db: any Database) async throws
    func findLatestActiveCode(forEmail email: String, on db: any Database) async throws -> PasswordResetToken?
    func findVerifiedSession(forEmail email: String, sessionTokenHash: String, on db: any Database) async throws -> PasswordResetToken?
    func consumeSessionIfActive(sessionTokenHash: String, email: String, on db: any Database) async throws -> Bool
    func cleanupExpiredOrUsed(before date: Date, on db: any Database) async throws -> Int
    func verifyOTPAndCreateSession(
        email: String,
        code: String,
        secret: String,
        on db: any Database
    ) async throws -> OTPVerificationOutcome
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer where K == DynamicCodingKey {
    func decode<T: Decodable>(_ type: T.Type, forKeys keys: [String]) throws -> T {
        for key in keys {
            if let codingKey = DynamicCodingKey(stringValue: key),
               let value = try? self.decode(T.self, forKey: codingKey) {
                return value
            }
        }
        let fallbackKey = DynamicCodingKey(stringValue: keys[0])!
        return try self.decode(T.self, forKey: fallbackKey)
    }
}

private struct ResetTokenRow: Decodable, Sendable {
    let id: UUID
    let email: String
    let codeHash: String
    let attempts: Int
    let codeExpiresAt: Date
    let verified: Bool
    let used: Bool

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)

        // ID decoding (UUID or String)
        if let uuid = try? container.decode(UUID.self, forKeys: ["id", "ID"]) {
            self.id = uuid
        } else if let str = try? container.decode(String.self, forKeys: ["id", "ID"]), let uuid = UUID(uuidString: str) {
            self.id = uuid
        } else {
            self.id = try container.decode(UUID.self, forKeys: ["id", "ID"])
        }

        self.email = try container.decode(String.self, forKeys: ["email", "EMAIL"])
        self.codeHash = try container.decode(String.self, forKeys: ["code_hash", "codeHash", "CODE_HASH"])
        self.attempts = try container.decode(Int.self, forKeys: ["attempts", "ATTEMPTS"])

        // code_expires_at decoding (Date, timestamp Double, or ISO-8601 String)
        if let date = try? container.decode(Date.self, forKeys: ["code_expires_at", "codeExpiresAt", "CODE_EXPIRES_AT"]) {
            self.codeExpiresAt = date
        } else if let timestamp = try? container.decode(Double.self, forKeys: ["code_expires_at", "codeExpiresAt", "CODE_EXPIRES_AT"]) {
            self.codeExpiresAt = Date(timeIntervalSince1970: timestamp)
        } else if let dateStr = try? container.decode(String.self, forKeys: ["code_expires_at", "codeExpiresAt", "CODE_EXPIRES_AT"]) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr) {
                self.codeExpiresAt = date
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid ISO-8601 date string: '\(dateStr)'")
                )
            }
        } else {
            self.codeExpiresAt = try container.decode(Date.self, forKeys: ["code_expires_at", "codeExpiresAt", "CODE_EXPIRES_AT"])
        }

        if let boolVal = try? container.decode(Bool.self, forKeys: ["verified", "VERIFIED"]) {
            self.verified = boolVal
        } else if let intVal = try? container.decode(Int.self, forKeys: ["verified", "VERIFIED"]) {
            self.verified = (intVal != 0)
        } else {
            self.verified = try container.decode(Bool.self, forKeys: ["verified", "VERIFIED"])
        }

        if let boolVal = try? container.decode(Bool.self, forKeys: ["used", "USED"]) {
            self.used = boolVal
        } else if let intVal = try? container.decode(Int.self, forKeys: ["used", "USED"]) {
            self.used = (intVal != 0)
        } else {
            self.used = try container.decode(Bool.self, forKeys: ["used", "USED"])
        }
    }
}

struct DatabasePasswordResetRepository: PasswordResetRepository {
    init() {}

    func create(_ token: PasswordResetToken, on db: any Database) async throws {
        try await token.save(on: db)
    }

    func update(_ token: PasswordResetToken, on db: any Database) async throws {
        try await token.save(on: db)
    }

    func invalidateAll(forEmail email: String, on db: any Database) async throws {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        try await PasswordResetToken.query(on: db)
            .filter(\.$email == normalizedEmail)
            .filter(\.$used == false)
            .set(\.$used, to: true)
            .update()
    }

    func findLatestActiveCode(forEmail email: String, on db: any Database) async throws -> PasswordResetToken? {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        return try await PasswordResetToken.query(on: db)
            .filter(\.$email == normalizedEmail)
            .filter(\.$used == false)
            .filter(\.$verified == false)
            .sort(\.$codeExpiresAt, .descending)
            .first()
    }

    func findVerifiedSession(forEmail email: String, sessionTokenHash: String, on db: any Database) async throws -> PasswordResetToken? {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        return try await PasswordResetToken.query(on: db)
            .filter(\.$email == normalizedEmail)
            .filter(\.$sessionTokenHash == sessionTokenHash)
            .filter(\.$verified == true)
            .filter(\.$used == false)
            .first()
    }

    func verifyOTPAndCreateSession(
        email: String,
        code: String,
        secret: String,
        on db: any Database
    ) async throws -> OTPVerificationOutcome {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "PasswordResetRepository requires an SQLDatabase-compatible driver.")
        }

        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        let dialect = sql.dialect.name.lowercased()
        let driverName = "\(type(of: db))".lowercased()
        let isPostgres = dialect.contains("postgres") || dialect.contains("psql") || driverName.contains("postgres") || driverName.contains("psql")
        let isSQLite = dialect.contains("sqlite") || driverName.contains("sqlite")
        let isMySQL = dialect.contains("mysql") || driverName.contains("mysql")

        // 1. Fetch latest active unverified token candidate
        let rows = try await sql.raw("""
            SELECT id, email, code_hash, attempts, code_expires_at, verified, used
            FROM password_reset_tokens
            WHERE email = \(bind: normalizedEmail)
              AND used = false
              AND verified = false
            ORDER BY code_expires_at DESC
            LIMIT 1
        """).all(decoding: ResetTokenRow.self)

        guard let tokenRow = rows.first else {
            return .invalidOrExpiredCode
        }

        // 2. Fast check: max attempts reached
        if tokenRow.attempts >= 3 {
            return .tooManyAttempts
        }

        // 3. Fast check: code expired
        if tokenRow.codeExpiresAt <= Date() {
            return .expired
        }

        // 4. Constant-time comparison of OTP HMAC
        let candidateHash = PasswordResetSecurity.hashOTP(code, email: normalizedEmail, secret: secret)
        let isMatch = PasswordResetSecurity.constantTimeCompare(candidateHash, tokenRow.codeHash)

        if !isMatch {
            // Atomic increment of attempt counter directly in the database
            struct AttemptOutcomeRow: Decodable {
                let attempts: Int
            }

            if isPostgres || isSQLite {
                let updated = try await sql.raw("""
                    UPDATE password_reset_tokens
                    SET attempts = attempts + 1,
                        used = CASE WHEN attempts + 1 >= 3 THEN true ELSE used END
                    WHERE id = \(bind: tokenRow.id)
                      AND used = false
                      AND verified = false
                    RETURNING attempts
                """).all(decoding: AttemptOutcomeRow.self)

                let currentAttempts = updated.first?.attempts ?? (tokenRow.attempts + 1)
                if currentAttempts >= 3 {
                    return .tooManyAttempts
                } else {
                    return .invalidCode(remainingAttempts: max(0, 3 - currentAttempts))
                }
            } else if isMySQL {
                try await sql.raw("""
                    UPDATE password_reset_tokens
                    SET attempts = attempts + 1,
                        used = CASE WHEN attempts + 1 >= 3 THEN 1 ELSE used END
                    WHERE id = \(bind: tokenRow.id)
                      AND used = 0
                      AND verified = 0
                """).run()

                struct MySQLAttempts: Decodable {
                    let attempts: Int
                }
                let current = try await sql.raw("""
                    SELECT attempts FROM password_reset_tokens WHERE id = \(bind: tokenRow.id)
                """).first(decoding: MySQLAttempts.self)
                let currentAttempts = current?.attempts ?? (tokenRow.attempts + 1)
                if currentAttempts >= 3 {
                    return .tooManyAttempts
                } else {
                    return .invalidCode(remainingAttempts: max(0, 3 - currentAttempts))
                }
            } else {
                return .invalidCode(remainingAttempts: max(0, 2 - tokenRow.attempts))
            }
        }

        // 5. Valid code: Generate 256-bit secure session token and hash
        let rawSessionToken = PasswordResetSecurity.generateSecureSessionToken()
        let sessionTokenHash = PasswordResetSecurity.hashSessionToken(rawSessionToken)
        let sessionExpiresAt = Date().addingTimeInterval(15 * 60)
        let now = Date()

        if isPostgres || isSQLite {
            struct TransitionRow: Decodable {
                let id: String
            }
            // Atomic conditional update: only 1 request can transition from verified = false to verified = true
            let updated = try await sql.raw("""
                UPDATE password_reset_tokens
                SET verified = true,
                    session_token_hash = \(bind: sessionTokenHash),
                    session_expires_at = \(bind: sessionExpiresAt)
                WHERE id = \(bind: tokenRow.id)
                  AND verified = false
                  AND used = false
                  AND code_expires_at > \(bind: now)
                  AND attempts < 3
                RETURNING id
            """).all(decoding: TransitionRow.self)

            guard !updated.isEmpty else {
                // Lost race condition: another concurrent caller successfully verified it first
                return .invalidOrExpiredCode
            }

            return .success(sessionToken: rawSessionToken)
        } else if isMySQL {
            try await sql.raw("""
                UPDATE password_reset_tokens
                SET verified = 1,
                    session_token_hash = \(bind: sessionTokenHash),
                    session_expires_at = \(bind: sessionExpiresAt)
                WHERE id = \(bind: tokenRow.id)
                  AND verified = 0
                  AND used = 0
                  AND code_expires_at > \(bind: now)
                  AND attempts < 3
            """).run()

            struct MySQLRowCount: Decodable {
                let affected: Int
                enum CodingKeys: String, CodingKey {
                    case affected = "ROW_COUNT()"
                }
            }
            let rowCount = try await sql.raw("SELECT ROW_COUNT()").first(decoding: MySQLRowCount.self)
            guard (rowCount?.affected ?? 0) > 0 else {
                return .invalidOrExpiredCode
            }

            return .success(sessionToken: rawSessionToken)
        } else {
            return .invalidOrExpiredCode
        }
    }

    func consumeSessionIfActive(sessionTokenHash: String, email: String, on db: any Database) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "PasswordResetRepository requires an SQLDatabase-compatible driver for atomic session consumption.")
        }

        let dialect = sql.dialect.name.lowercased()
        let driverName = "\(type(of: db))".lowercased()
        let isPostgres = dialect.contains("postgres") || dialect.contains("psql") || driverName.contains("postgres") || driverName.contains("psql")
        let isSQLite = dialect.contains("sqlite") || driverName.contains("sqlite")
        let isMySQL = dialect.contains("mysql") || driverName.contains("mysql")
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        let now = Date()

        if isPostgres || isSQLite {
            struct ConsumedRow: Decodable {
                let id: String
            }
            let rows = try await sql.raw("""
                UPDATE password_reset_tokens
                SET used = true
                WHERE session_token_hash = \(bind: sessionTokenHash)
                  AND email = \(bind: normalizedEmail)
                  AND verified = true
                  AND used = false
                  AND session_expires_at > \(bind: now)
                RETURNING id
            """).all(decoding: ConsumedRow.self)

            return !rows.isEmpty
        } else if isMySQL {
            struct MySQLResetRow: Decodable {
                let id: String
            }
            // Acquire row-level exclusive lock within enclosing transaction
            let rows = try await sql.raw("""
                SELECT id
                FROM password_reset_tokens
                WHERE session_token_hash = \(bind: sessionTokenHash)
                  AND email = \(bind: normalizedEmail)
                  AND verified = true
                  AND used = false
                  AND session_expires_at > \(bind: now)
                FOR UPDATE
            """).all(decoding: MySQLResetRow.self)

            guard let first = rows.first else {
                return false
            }

            try await sql.raw("""
                UPDATE password_reset_tokens
                SET used = true
                WHERE id = \(bind: first.id)
            """).run()

            return true
        } else {
            throw Abort(.internalServerError, reason: "Unsupported SQL dialect for atomic reset session consumption.")
        }
    }

    func cleanupExpiredOrUsed(before date: Date, on db: any Database) async throws -> Int {
        let staleTokens = try await PasswordResetToken.query(on: db)
            .group(.or) { group in
                group.filter(\.$used == true)
                group.group(.and) { andGroup in
                    andGroup.filter(\.$codeExpiresAt < date)
                    andGroup.filter(\.$verified == false)
                }
                group.group(.and) { andGroup in
                    andGroup.filter(\.$sessionExpiresAt != nil)
                    andGroup.filter(\.$sessionExpiresAt < date)
                }
            }
            .all()

        let count = staleTokens.count
        try await staleTokens.delete(on: db)
        return count
    }
}
