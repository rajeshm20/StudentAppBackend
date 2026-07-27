import Vapor

enum AppConfig {
    enum DatabaseTLSMode {
        case disable
        case verifyFull
        case noVerify
    }

    static let minimumJWTSecretLength = 32
    static let defaultJWTAccessTTL: TimeInterval = 3600

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
