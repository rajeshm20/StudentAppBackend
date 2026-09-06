import NIOSSL
import Vapor

enum AppConfig {
    enum DatabaseTLSMode {
        case disable
        case verifyFull
        case noVerify
    }

    static let minimumJWTSecretLength = 32
    static let defaultJWTAccessTTL: TimeInterval = 3600

    /// Industry-standard hardened cipher suites for TLS 1.2 enforcing Perfect Forward Secrecy (ECDHE)
    /// and Authenticated Encryption (AEAD: AES-GCM and ChaCha20-Poly1305).
    /// Disallows legacy CBC-mode ciphers, static RSA, RC4, 3DES, and MD5.
    static let defaultSecureCipherSuites: String = [
        "ECDHE-ECDSA-AES128-GCM-SHA256",
        "ECDHE-RSA-AES128-GCM-SHA256",
        "ECDHE-ECDSA-AES256-GCM-SHA384",
        "ECDHE-RSA-AES256-GCM-SHA384",
        "ECDHE-ECDSA-CHACHA20-POLY1305",
        "ECDHE-RSA-CHACHA20-POLY1305"
    ].joined(separator: ":")

    static func jwtAccessTTL() -> TimeInterval {
        guard let raw = Environment.get("JWT_ACCESS_TTL"), let seconds = TimeInterval(raw), seconds > 0 else {
            return defaultJWTAccessTTL
        }
        return seconds
    }

    static func loadJWTSecret(for environment: Environment) throws -> String {
        if let secret = Environment.get("JWT_SECRET"), !secret.isEmpty {
            if environment == .production && secret.count < minimumJWTSecretLength {
                throw Abort(
                    .internalServerError,
                    reason: "JWT_SECRET must be at least \(minimumJWTSecretLength) characters in production"
                )
            }
            return secret
        }

        if environment == .testing {
            return "test-jwt-secret-at-least-32-characters-long"
        }

        throw Abort(.internalServerError, reason: "JWT_SECRET environment variable is required")
    }

    static func shouldAutoMigrate(in environment: Environment) -> Bool {
        if environment == .testing {
            return false
        }

        let flag = Environment.get("AUTO_MIGRATE")?.lowercased()
        return flag == "1" || flag == "true" || flag == "yes"
    }

    static func isGraphiQLEnabled(in environment: Environment) -> Bool {
        if environment == .production {
            return false
        }

        let flag = Environment.get("ENABLE_GRAPHIQL")?.lowercased()
        return flag == "1" || flag == "true" || flag == "yes"
    }

    static func corsAllowedOrigin(for environment: Environment) throws -> CORSMiddleware.AllowOriginSetting {
        if let origin = Environment.get("ALLOWED_ORIGIN"), !origin.isEmpty, origin != "*" {
            return .custom(origin)
        }

        if environment == .production {
            throw Abort(
                .internalServerError,
                reason: "ALLOWED_ORIGIN must be set to an explicit origin in production"
            )
        }

        return .custom(Environment.get("ALLOWED_ORIGIN") ?? "http://localhost:8081")
    }

    /// Determines the minimum TLS version to enforce for TLS listeners and clients.
    /// Defaults to TLS 1.2 (.tlsv12). Supports upgrading to TLS 1.3 (.tlsv13).
    /// Strictly rejects insecure versions (TLS 1.0, TLS 1.1) in production.
    static func minimumTLSVersion(for environment: Environment) throws -> TLSVersion {
        guard let raw = Environment.get("TLS_MIN_VERSION")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return .tlsv12
        }

        switch raw {
        case "1.2", "tlsv12", "tlsv1.2", "tls1.2":
            return .tlsv12
        case "1.3", "tlsv13", "tlsv1.3", "tls1.3":
            return .tlsv13
        case "1.0", "1.1", "tlsv1", "tlsv1.0", "tlsv11", "tlsv1.1", "tls1.0", "tls1.1":
            if environment == .production {
                throw Abort(
                    .internalServerError,
                    reason: "Insecure TLS version '\(raw)' is forbidden in production. Minimum supported version is TLS 1.2."
                )
            }
            // Clamped to TLS 1.2 for security in non-production environments
            return .tlsv12
        default:
            throw Abort(
                .internalServerError,
                reason: "Unsupported TLS_MIN_VERSION: '\(raw)'. Supported values are '1.2' and '1.3'."
            )
        }
    }

    /// Returns the cipher suites string to use for TLS 1.2 negotiations.
    /// Can be overridden via TLS_CIPHER_SUITES environment variable.
    static func tlsCipherSuites(for environment: Environment) -> String {
        if let custom = Environment.get("TLS_CIPHER_SUITES")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return defaultSecureCipherSuites
    }

    static func validateProductionSecrets(for environment: Environment) throws {
        guard environment == .production else {
            return
        }

        if let password = Environment.get("DATABASE_PASSWORD"),
           password == "newpassword" || password == "password" {
            throw Abort(
                .internalServerError,
                reason: "DATABASE_PASSWORD must not use default values in production"
            )
        }

        // Validate TLS minimum version setting
        _ = try minimumTLSVersion(for: environment)

        // Validate HTTPS certificate configuration if enabled in production
        let httpsFlag = Environment.get("ENABLE_HTTPS")?.lowercased()
        if httpsFlag == "1" || httpsFlag == "true" || httpsFlag == "yes" {
            let certPath = Environment.get("TLS_CERT") ?? "certs/cert.pem"
            let keyPath = Environment.get("TLS_KEY") ?? "certs/key.pem"
            if !FileManager.default.fileExists(atPath: certPath) || !FileManager.default.fileExists(atPath: keyPath) {
                throw Abort(
                    .internalServerError,
                    reason: "ENABLE_HTTPS is set to true in production but TLS_CERT ('\(certPath)') or TLS_KEY ('\(keyPath)') is missing"
                )
            }
        }
    }

    static func databaseTLSMode(for environment: Environment) -> DatabaseTLSMode {
        switch Environment.get("DATABASE_TLS_MODE")?.lowercased() {
        case "disable", "disabled", "off":
            return .disable
        case "insecure", "no-verify", "skip-verify":
            return .noVerify
        case "require", "verify-full", "full":
            return .verifyFull
        default:
            return environment == .production ? .verifyFull : .noVerify
        }
    }
}
