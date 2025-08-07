// MARK: - routes.swift
import Vapor

func routes(_ app: Application) throws {
    try app.register(collection: AuthController())
    for route in app.routes.all {
        let path = route.path.map { "\($0)" }.joined(separator: "/")
        print("Route: \(route.method.rawValue) /\(path)")
    }}
