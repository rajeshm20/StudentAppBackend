    // MARK: - configure.swift
import Vapor
import Fluent
import SQLKit
import FluentMySQLDriver
import JWTKit
import JWT
import Logging
import NIOSSL
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

public func configure(_ app: Application) throws {
        // Continue with your routes / middleware
    switch app.environment {
        case .testing :
            app.databases.use(.mysql(
                hostname: Environment.get("DATABASE_HOST") ?? "localhost",
                port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? MySQLConfiguration.ianaPortNumber,
                username: Environment.get("DATABASE_USER") ?? "root",
                password: Environment.get("DATABASE_PASSWORD") ?? "password",
                database: Environment.get("DATABASE_NAME") ?? "student_db",
                tlsConfiguration: {
                    var tls = TLSConfiguration.makeClientConfiguration()
                    tls.certificateVerification = Environment.get("ENVIRONMENT") == "production" ? .fullVerification : .none
                    return tls
                }()
            ), as: .mysql)
                // 🔹 Create CORS configuration
            let allowedOrigin = Environment.get("ALLOWED_ORIGIN") ?? "http://jenkins.local:8081"
            let corsConfig = CORSMiddleware.Configuration(
                allowedOrigin: .custom("https://openedschool.com"), // 👈 restrict to your frontend
                allowedMethods: [.GET, .POST, .PUT, .DELETE, .OPTIONS],
                allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith],
                allowCredentials: true
            )
                // 🔹 Build the middleware from config
            let cors = CORSMiddleware(configuration: corsConfig)
                // 🔹 Register middleware in correct order
            app.middleware.use(cors)                        // CORS first
            app.middleware.use(SecurityHeadersMiddleware()) // Your custom headers
            app.middleware.use(RateLimiterMiddleware())     // Rate limiting
            guard let jwtSecret = Environment.get("JWT_SECRET") else {
                fatalError("JWT_SECRET environment variable is required")
            }
            app.jwt.signers.use(.hs256(key: jwtSecret.data(using: .utf8)!))
                // Add migrations
            app.migrations.add(CreateStudent())
            app.migrations.add(CreateRevokedToken())
            app.migrations.add(CreatePasswordResetToken())
            try app.autoMigrate().wait()
                // In configure.swift
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
                // Note: TLS is intentionally NOT configured here. certs/ is
                // gitignored and won't exist in CI or on a fresh checkout, and
                // the in-process test client (app.testable()) doesn't need a
                // real TLS listener anyway. Loading certs unconditionally here
                // previously threw `failedToLoadCertificate` and failed every
                // test before it could even run. If you need TLS exercised in
                // a specific test, guard it the same way the `default` case
                // below does (shouldEnableTLS + do/catch) instead of `try`.

            try routes(app)
        default:
            app.databases.use(.mysql(
                hostname: Environment.get("DATABASE_HOST") ?? "localhost",
                port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? MySQLConfiguration.ianaPortNumber,
                username: Environment.get("DATABASE_USER") ?? "root",
                password: Environment.get("DATABASE_PASSWORD") ?? "newpassword",
                database: Environment.get("DATABASE_NAME") ?? "student_db",
                //            tlsConfiguration: .makeClientConfiguration()
                tlsConfiguration: {
                    var tls = TLSConfiguration.makeClientConfiguration()
                    tls.certificateVerification = Environment.get("ENVIRONMENT") == "production" ? .fullVerification : .none
                    return tls
                }()
            ), as: .mysql)

                // 🔹 Create CORS configuration
            let corsConfig = CORSMiddleware.Configuration(
                allowedOrigin: .custom(Environment.get("ALLOWED_ORIGIN") ?? "*"), // 👈 restrict to your frontend
                allowedMethods: [.GET, .POST, .PUT, .DELETE, .OPTIONS],
                allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith],
                allowCredentials: true
            )
                // 🔹 Build the middleware from config
            let cors = CORSMiddleware(configuration: corsConfig)
                // 🔹 Register middleware in correct order
            app.middleware.use(cors)                        // CORS first
            app.middleware.use(SecurityHeadersMiddleware()) // Your custom headers
            app.middleware.use(RateLimiterMiddleware())     // Rate limiting
                // Certificates path has been set in Edit Scheme -> RUN -> Arguments, if any change of folders or path should be changed here too.
            let certPath = Environment.get("TLS_CERT") ?? "certs/cert.pem"
            let keyPath  = Environment.get("TLS_KEY")  ?? "certs/key.pem"
            let tlsEnabled = shouldEnableTLS(certPath: certPath, keyPath: keyPath)

            print("PWD:", FileManager.default.currentDirectoryPath)
            print("Cert path:", certPath)
            print("Key path:", keyPath)
            print("Cert exists:", FileManager.default.fileExists(atPath: certPath))
            print("Key exists:", FileManager.default.fileExists(atPath: keyPath))

            if tlsEnabled {
                do {
                    let certs = try NIOSSLCertificate.fromPEMFile(certPath).map { NIOSSLCertificateSource.certificate($0) }
                    let nioPrivateKey = try NIOSSLPrivateKey(file: keyPath, format: .pem)
                    let tls = TLSConfiguration.makeServerConfiguration(
                        certificateChain: certs,
                        privateKey: .privateKey(nioPrivateKey)
                    )
                    app.http.server.configuration.tlsConfiguration = tls
                    print("Loaded \(certs.count) certificate(s)")
                } catch {
                    app.logger.warning("TLS certificates could not be loaded. Continuing without HTTPS: \(error)")
                }
            } else {
                app.logger.notice("HTTPS disabled. Starting server on HTTP.")
            }

                // In configure.swift
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

        // JWT setup
            guard let jwtSecret = Environment.get("JWT_SECRET") else {
                fatalError("JWT_SECRET environment variable is required")
            }
        app.jwt.signers.use(.hs256(key: jwtSecret.data(using: .utf8)!))
        // Add migrations
        app.migrations.add(CreateStudent())
        app.migrations.add(CreateRevokedToken())
        app.migrations.add(CreatePasswordResetToken())
        try app.autoMigrate().wait()
        try routes(app)

    }

}
#if DEBUG
public func main() async throws {
    try await configure(Application.make())
}
#endif
