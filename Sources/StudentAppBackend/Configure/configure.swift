// MARK: - configure.swift
import Vapor
import Fluent
import SQLKit
import FluentMySQLDriver
import JWTKit
import JWT
import Logging
import NIOSSL

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
                    tls.certificateVerification = .none
                    return tls
                }()
            ), as: .mysql)
            // 🔹 Create CORS configuration
            let corsConfig = CORSMiddleware.Configuration(
                allowedOrigin: .custom("https://studentapp.ddns.net"), // 👈 restrict to your frontend
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
            
            // Load certificates and private key (PEM) and use the non-deprecated API
            let certChain = try NIOSSLCertificate.fromPEMFile(certPath).map { NIOSSLCertificateSource.certificate($0) }
            // If your key is password-protected, use `NIOSSLPrivateKey(file: keyPath, format: .pem, password: "yourPassword")`
            let nioPrivateKey = try NIOSSLPrivateKey(file: keyPath, format: .pem)
            app.http.server.configuration.tlsConfiguration = TLSConfiguration.makeServerConfiguration(
                certificateChain: certChain,
                privateKey: .privateKey(nioPrivateKey)
            )
            print("PWD:", FileManager.default.currentDirectoryPath)
            print("Cert:", certPath)
            print("Key:", keyPath)
            print("Cert exists:", FileManager.default.fileExists(atPath: certPath))
            print("Key exists:", FileManager.default.fileExists(atPath: keyPath))

            try routes(app)
        default:
//        app.get("databases") { req async throws -> [String] in
//            let db = req.db
//            let rows = try await db.raw("SHOW DATABASES;").all()
//            return rows.compactMap { row in
//                row.column("Database")?.string
//            }
//        }
//        
//        app.get("tables", ":db") { req async throws -> [String] in
//            guard let dbName = req.parameters.get("db") else {
//                throw Abort(.badRequest, reason: "Database name required")
//            }
//            
//            let db = req.db
//            let rows = try await db.raw("SHOW TABLES IN \(raw: dbName);").all()
//            
//            // column name changes depending on MySQL version: usually "Tables_in_<dbName>"
//            let key = "Tables_in_\(dbName)"
//            return rows.compactMap { row in
//                row.column(key)?.string
//            }
//        }

            app.databases.use(.mysql(
                hostname: Environment.get("DATABASE_HOST") ?? "localhost",
                port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? MySQLConfiguration.ianaPortNumber,
                username: Environment.get("DATABASE_USER") ?? "root",
                password: Environment.get("DATABASE_PASSWORD") ?? "newpassword",
                database: Environment.get("DATABASE_NAME") ?? "student_db",
    //            tlsConfiguration: .makeClientConfiguration()
                tlsConfiguration: {
                    var tls = TLSConfiguration.makeClientConfiguration()
                    tls.certificateVerification = .none
                    return tls
                }()
            ), as: .mysql)
            
            // 🔹 Create CORS configuration
            let corsConfig = CORSMiddleware.Configuration(
                allowedOrigin: .custom("https://127.0.0.1:8080"), // 👈 restrict to your frontend
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
