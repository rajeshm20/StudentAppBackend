// MARK: - routes.swift
import Vapor
import Logging

func routes(_ app: Application) throws {
    try app.register(collection: AuthController())
    try registerGraphQLRoutes(app)
    for route in app.routes.all {
        let path = route.path.map { "\($0)" }.joined(separator: "/")
        print("Route: \(route.method.rawValue) /\(path)")
        var logger1 = Logger(label: "first logger")
        logger1.logLevel = .debug
        logger1[metadataKey: "only-on"] = "Route: \(route.method.rawValue) /\(path)"
    }}
