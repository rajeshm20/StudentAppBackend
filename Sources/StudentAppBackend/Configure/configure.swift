// MARK: - configure.swift
import Vapor
import Fluent
import FluentMySQLDriver
import JWTKit
import JWT
import Logging
import NIOSSL
public func configure(_ app: Application) throws {
        // Continue with your routes / middleware
    switch app.environment {
        case .testing :
            app.databases.use(.mysql(
                hostname: "localhost",
                username: "root",
                password: "",
                database: "student_app_test_db",
    //            tlsConfiguration: .makeClientConfiguration()
                tlsConfiguration: .forClient(certificateVerification: .none)
            ), as: .mysql)
            // 🔹 Create CORS configuration
            let corsConfig = CORSMiddleware.Configuration(
                allowedOrigin: .custom("https://your-frontend-domain.com"), // 👈 restrict to your frontend
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
            app.jwt.signers.use(.hs256(key: "your-secret-key".data(using: .utf8)!))
            // Add migrations
            app.migrations.add(CreateStudent())
            try app.autoMigrate().wait()
        
            let certPath = Environment.get("TLS_CERT") ?? "certs/cert.pem"
            let keyPath  = Environment.get("TLS_KEY")  ?? "certs/key.pem"

            app.http.server.configuration.hostname = "127.0.0.1"
            app.http.server.configuration.port = 8443
            
            app.http.server.configuration.tlsConfiguration = try .makeServerConfiguration(
                certificateChain: [
                    .certificate(.init(file: certPath, format: .pem))
                ],
                privateKey: .file(keyPath)
            )

            try routes(app)
        default:
            app.databases.use(.mysql(
                hostname: Environment.get("DATABASE_HOST") ?? "localhost",
                port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? MySQLConfiguration.ianaPortNumber,
                username: Environment.get("DATABASE_USER") ?? "root",
                password: Environment.get("DATABASE_PASSWORD") ?? "newpassword",
                database: Environment.get("DATABASE_NAME") ?? "student_db",
    //            tlsConfiguration: .makeClientConfiguration()
                tlsConfiguration: .forClient(certificateVerification: .none)
            ), as: .mysql)
            
            // 🔹 Create CORS configuration
            let corsConfig = CORSMiddleware.Configuration(
                allowedOrigin: .custom("https://your-frontend-domain.com"), // 👈 restrict to your frontend
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
#if DEBUG

            print("---- ENVIRONMENT VARIABLES ----")
            for (key, value) in ProcessInfo.processInfo.environment {
                print("\(key) = \(value)")
            }
            print("---- END ENV ----")

            // Example: Access a specific one
            if let dbUser = Environment.get("DATABASE_USER") {
                print("DATABASE_USER is \(dbUser)")
            } else {
                print("DATABASE_USER not found")
            }
#endif
        let certPath = Environment.get("TLS_CERT") ?? "certs/cert.pem"
        let keyPath  = Environment.get("TLS_KEY")  ?? "certs/key.pem"

        let certs = try NIOSSLCertificate.fromPEMFile(certPath).map { NIOSSLCertificateSource.certificate($0) }
        let tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: certs,
            privateKey: .file(keyPath)
        )

        app.http.server.configuration.tlsConfiguration = tls
            // JWT setup
            app.jwt.signers.use(.hs256(key: "your-secret-key".data(using: .utf8)!))
            // Add migrations
            app.migrations.add(CreateStudent())
            try app.autoMigrate().wait()
            try routes(app)
        }
}
#if DEBUG
public func main() async throws {
    try await configure(Application.make())
}
#endif
