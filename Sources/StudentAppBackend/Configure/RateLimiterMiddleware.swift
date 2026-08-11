//
//  RateLimiterMiddleware.swift
//  StudentAppBackend
//
//  Created by Rajesh Mani on 16/08/25.
//

import Vapor
import NIOConcurrencyHelpers
import NIOCore

//// MARK: 1. Security Headers Middleware
////MARK: ⏳ 2. Rate Limiting Middleware

actor RateLimiterStore {
    private var clients: [String: [String: (count: Int, resetTime: Date)]] = [:]
    // clients[ip] = [route: (count, resetTime)]

    func check(ip: String, route: String, maxRequests: Int, windowSeconds: Int) -> Bool {
        let now = Date()
        var routeLimits = clients[ip] ?? [:]

        if var record = routeLimits[route] {
            if now > record.resetTime {
                record = (1, now.addingTimeInterval(TimeInterval(windowSeconds)))
            } else {
                record.count += 1
            }
            routeLimits[route] = record
            clients[ip] = routeLimits
            return record.count <= maxRequests
        } else {
            routeLimits[route] = (1, now.addingTimeInterval(TimeInterval(windowSeconds)))
            clients[ip] = routeLimits
            return true
        }
    }
}

final class RateLimiterMiddleware: AsyncMiddleware {
    private let store = RateLimiterStore()

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let ip = request.remoteAddress?.ipAddress ?? "unknown"
        let route = request.url.path

        // 🎯 Different rules depending on endpoint
        let (maxRequests, windowSeconds): (Int, Int) = {
            if route.starts(with: "/auth/login") {
                return (5, 60)
            } else if route.starts(with: "/auth/forgot-password") || route.starts(with: "/auth/verify-reset-code") {
                return (3, 60)
            } else {
                return (100, 60)
            }
        }()

        let allowed = await store.check(ip: ip, route: route, maxRequests: maxRequests, windowSeconds: windowSeconds)

        guard allowed else {
            throw Abort(.tooManyRequests, reason: "Too many requests to \(route). Try again later.")
        }

        return try await next.respond(to: request)
    }
}
