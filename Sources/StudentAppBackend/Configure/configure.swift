import Fluent
import FluentMySQLDriver
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

private func databaseTLSConfiguration(for environment: Environment) -> TLSConfiguration? {
    switch AppConfig.databaseTLSMode(for: environment) {
    case .disable:
        return nil
    case .verifyFull:
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .fullVerification
        return tls
    case .noVerify:
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .none
        return tls
    }
}

private func configureDatabase(_ app: Application) {
    if app.environment == .testing || Environment.get("DATABASE_DRIVER")?.lowercased() == "sqlite" {
        app.databases.use(.sqlite(.memory), as: .sqlite, isDefault: true)
        return
    }

    app.databases.use(.mysql(
        hostname: Environment.get("DATABASE_HOST") ?? "localhost",
        port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? MySQLConfiguration.ianaPortNumber,
        username: Environment.get("DATABASE_USER") ?? "root",
        password: Environment.get("DATABASE_PASSWORD") ?? "newpassword",
        database: Environment.get("DATABASE_NAME") ?? "student_db",
        tlsConfiguration: databaseTLSConfiguration(for: app.environment)
    ), as: .mysql)
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

private func configureTLS(_ app: Application) {
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
        let tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: certs,
            privateKey: .privateKey(nioPrivateKey)
        )
        app.http.server.configuration.tlsConfiguration = tls
        app.logger.notice("Loaded \(certs.count) TLS certificate(s)")
    } catch {
        app.logger.warning("TLS certificates could not be loaded. Continuing without HTTPS: \(error)")
    }
}

public func configure(_ app: Application) throws {
    try AppConfig.validateProductionSecrets(for: app.environment)
    configureDatabase(app)
    try configureMiddleware(app)
    try configureJWT(app)
    configureEmail(app)
    configureTLS(app)
    try configureMigrations(app)
    try routes(app)
}

#if DEBUG
public func main() async throws {
    try await configure(Application.make())
}
#endif
