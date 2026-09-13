import Fluent
import FluentMySQLDriver
import FluentPostgresDriver
import FluentSQLiteDriver
import JWT
import JWTKit
import Logging
import NIOSSL
import SQLKit
import Vapor

extension Application {
    private struct EmailServiceKey: StorageKey {
        typealias Value = EmailSending
    }

    var emailService: any EmailSending {
        get {
            guard let service = storage[EmailServiceKey.self] else {
                fatalError("EmailService not configured")
            }
            return service
        }
        set { storage[EmailServiceKey.self] = newValue }
    }
}

private func shouldEnableTLS(certPath: String, keyPath: String) -> Bool {
    let flag = Environment.get("ENABLE_HTTPS")?.lowercased()
    let tlsRequested = flag == "1" || flag == "true" || flag == "yes"
    let hasTLSFiles = FileManager.default.fileExists(atPath: certPath)
        && FileManager.default.fileExists(atPath: keyPath)
    return tlsRequested && hasTLSFiles
}

func databaseTLSConfiguration(for environment: Environment) -> TLSConfiguration? {
    switch AppConfig.databaseTLSMode(for: environment) {
    case .disable:
        return nil
    case .verifyFull:
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .fullVerification
        tls.minimumTLSVersion = (try? AppConfig.minimumTLSVersion(for: environment)) ?? .tlsv12
        tls.cipherSuites = AppConfig.tlsCipherSuites(for: environment)
        return tls
    case .noVerify:
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .none
        tls.minimumTLSVersion = (try? AppConfig.minimumTLSVersion(for: environment)) ?? .tlsv12
        tls.cipherSuites = AppConfig.tlsCipherSuites(for: environment)
        return tls
    }
}

private func configureDatabase(_ app: Application) throws {
    let driver = (Environment.get("DB_DRIVER") ?? Environment.get("DATABASE_DRIVER") ?? "postgres").lowercased()

    if (app.environment == .testing && Environment.get("DB_DRIVER") == nil && Environment.get("DATABASE_DRIVER") == nil) || driver == "sqlite" {
        app.databases.use(.sqlite(.memory), as: .sqlite, isDefault: true)
        return
    }

    switch driver {
    case "postgres", "psql", "postgresql":
        if let dbURL = Environment.get("DATABASE_URL"), !dbURL.isEmpty {
            try app.databases.use(.postgres(url: dbURL), as: .psql)
            return
        }

        guard let host = Environment.get("DATABASE_HOST"), !host.isEmpty else {
            throw Abort(.internalServerError, reason: "DATABASE_HOST environment variable is required")
        }
        let port = Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? 5432
        guard let user = Environment.get("DATABASE_USER"), !user.isEmpty else {
            throw Abort(.internalServerError, reason: "DATABASE_USER environment variable is required")
        }
        guard let password = Environment.get("DATABASE_PASSWORD"), !password.isEmpty else {
            throw Abort(.internalServerError, reason: "DATABASE_PASSWORD environment variable is required")
        }
        guard let database = Environment.get("DATABASE_NAME"), !database.isEmpty else {
            throw Abort(.internalServerError, reason: "DATABASE_NAME environment variable is required")
        }

        let tlsConfig: PostgresConnection.Configuration.TLS
        switch AppConfig.databaseTLSMode(for: app.environment) {
        case .disable:
            tlsConfig = .disable
        case .verifyFull:
            if let tls = databaseTLSConfiguration(for: app.environment) {
                let sslContext = try NIOSSLContext(configuration: tls)
                tlsConfig = .require(sslContext)
            } else {
                tlsConfig = .disable
            }
        case .noVerify:
            if let tls = databaseTLSConfiguration(for: app.environment) {
                let sslContext = try NIOSSLContext(configuration: tls)
                tlsConfig = .prefer(sslContext)
            } else {
                tlsConfig = .disable
            }
        }

        let postgresConfig = SQLPostgresConfiguration(
            hostname: host,
            port: port,
            username: user,
            password: password,
            database: database,
            tls: tlsConfig
        )
        app.databases.use(.postgres(configuration: postgresConfig), as: .psql)

    case "mysql":
        guard let host = Environment.get("DATABASE_HOST"), !host.isEmpty else {
            throw Abort(.internalServerError, reason: "DATABASE_HOST environment variable is required")
        }
        let port = Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? MySQLConfiguration.ianaPortNumber
        guard let user = Environment.get("DATABASE_USER"), !user.isEmpty else {
            throw Abort(.internalServerError, reason: "DATABASE_USER environment variable is required")
        }
        guard let password = Environment.get("DATABASE_PASSWORD"), !password.isEmpty else {
            throw Abort(.internalServerError, reason: "DATABASE_PASSWORD environment variable is required")
        }
        guard let database = Environment.get("DATABASE_NAME"), !database.isEmpty else {
            throw Abort(.internalServerError, reason: "DATABASE_NAME environment variable is required")
        }

        app.databases.use(.mysql(
            hostname: host,
            port: port,
            username: user,
            password: password,
            database: database,
            tlsConfiguration: databaseTLSConfiguration(for: app.environment)
        ), as: .mysql)

    default:
        throw Abort(.internalServerError, reason: "Unsupported DB_DRIVER: '\(driver)'. Supported values: 'postgres', 'mysql', 'sqlite'.")
    }
}

private func configureMiddleware(_ app: Application) throws {
    let corsConfig = CORSMiddleware.Configuration(
        allowedOrigin: try AppConfig.corsAllowedOrigin(for: app.environment),
        allowedMethods: [.GET, .POST, .PUT, .DELETE, .OPTIONS],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith],
        allowCredentials: true
    )

    app.middleware.use(CORSMiddleware(configuration: corsConfig))
    app.middleware.use(SecurityHeadersMiddleware())
    app.middleware.use(RateLimiterMiddleware())
}

private func configureJWT(_ app: Application) throws {
    let jwtSecret = try AppConfig.loadJWTSecret(for: app.environment)
    app.jwt.signers.use(.hs256(key: jwtSecret.data(using: .utf8)!))
}

private func configureEmail(_ app: Application) {
    if let sendGridKey = Environment.get("SENDGRID_API_KEY") {
        app.emailService = SendGridEmailService(
            apiKey: sendGridKey,
            fromEmail: Environment.get("FROM_EMAIL") ?? "noreply@openedschool.com",
            httpClient: app.http.client.shared
        )
    } else {
        app.logger.warning("SENDGRID_API_KEY not set — falling back to console email logging")
        app.emailService = ConsoleEmailService(logger: app.logger)
    }
}

private func configureMigrations(_ app: Application) throws {
    app.migrations.add(CreateStudent())
    app.migrations.add(CreateRevokedToken())
    app.migrations.add(CreatePasswordResetToken())
    // Phase 2: Role, status, firstName, lastName, countryCode, contactNumber (E.164), timestamps
    app.migrations.add(AddRoleStatusPhoneToStudents())

    if AppConfig.shouldAutoMigrate(in: app.environment) {
        app.logger.notice("AUTO_MIGRATE enabled — running migrations on startup")
        try app.autoMigrate().wait()
    } else if app.environment == .production {
        app.logger.notice("Skipping autoMigrate in production — run the migrate command before starting the app")
    }
}

func configureTLS(_ app: Application) throws {
    guard app.environment != .testing else {
        return
    }

    let certPath = Environment.get("TLS_CERT") ?? "certs/cert.pem"
    let keyPath = Environment.get("TLS_KEY") ?? "certs/key.pem"
    let tlsEnabled = shouldEnableTLS(certPath: certPath, keyPath: keyPath)

    #if DEBUG
    app.logger.debug("TLS cert path: \(certPath), exists: \(FileManager.default.fileExists(atPath: certPath))")
    app.logger.debug("TLS key path: \(keyPath), exists: \(FileManager.default.fileExists(atPath: keyPath))")
    #endif

    guard tlsEnabled else {
        app.logger.notice("HTTPS disabled. Starting server on HTTP.")
        return
    }

    do {
        let certs = try NIOSSLCertificate.fromPEMFile(certPath).map { NIOSSLCertificateSource.certificate($0) }
        let nioPrivateKey = try NIOSSLPrivateKey(file: keyPath, format: .pem)
        let minTLSVersion = try AppConfig.minimumTLSVersion(for: app.environment)
        let cipherSuites = AppConfig.tlsCipherSuites(for: app.environment)

        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: certs,
            privateKey: .privateKey(nioPrivateKey)
        )
        tls.minimumTLSVersion = minTLSVersion
        tls.cipherSuites = cipherSuites

        app.http.server.configuration.tlsConfiguration = tls
        app.logger.notice("Loaded \(certs.count) TLS certificate(s). Enforcing minimum TLS version: \(minTLSVersion) with hardened cipher suites.")
    } catch {
        if app.environment == .production {
            app.logger.error("Failed to configure TLS in production: \(error)")
            throw error
        } else {
            app.logger.warning("TLS certificates could not be loaded. Continuing without HTTPS: \(error)")
        }
    }
}

public func configure(_ app: Application) throws {
    try AppConfig.validateProductionSecrets(for: app.environment)
    try configureDatabase(app)
    try configureMiddleware(app)
    try configureJWT(app)
    configureEmail(app)
    try configureTLS(app)
    try configureMigrations(app)
    try routes(app)
}

#if DEBUG
public func main() async throws {
    try await configure(Application.make())
}
#endif
