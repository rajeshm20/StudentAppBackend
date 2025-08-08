// MARK: - configure.swift
import Vapor
import Fluent
import FluentMySQLDriver
import JWTKit
import JWT
import Logging

public func configure(_ app: Application) throws {
    if app.environment == .testing {
        app.databases.use(.mysql(
            hostname: "localhost",
            username: "root",
            password: "",
            database: "student_app_test_db",
            tlsConfiguration: .makeClientConfiguration()
        ), as: .mysql)
        // JWT setup
        app.jwt.signers.use(.hs256(key: "your-secret-key".data(using: .utf8)!))
        // Add migrations
        app.migrations.add(CreateStudent())
        try app.autoMigrate().wait()
        try routes(app)
    } else {
        app.databases.use(.mysql(
            hostname: Environment.get("DB_HOST") ?? "localhost",
            port: Environment.get("DB_PORT").flatMap(Int.init(_:)) ?? MySQLConfiguration.ianaPortNumber,
            username: Environment.get("DB_USER") ?? "root",
            password: Environment.get("DB_PASSWORD") ?? "password",
            database: Environment.get("DB_NAME") ?? "student_db",
            tlsConfiguration: .makeClientConfiguration()
        ), as: .mysql)
        // JWT setup
        app.jwt.signers.use(.hs256(key: "your-secret-key".data(using: .utf8)!))
        // Add migrations
        app.migrations.add(CreateStudent())
        try app.autoMigrate().wait()
        try routes(app)
    }
}
//#if DEBUG
//public func main() throws {
//    try configure(Application())
//}
//#endif
