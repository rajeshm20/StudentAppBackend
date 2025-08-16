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
//
//final actor RateLimiterMiddleware: AsyncMiddleware {
//    private let maxRequests: Int
//    private let window: TimeAmount
//    private var clients: [String: (count: Int, resetTime: Date)] = [:]
//    private let lock = NIOLock()
//
//    init(maxRequests: Int = 100, window: TimeAmount = .seconds(60)) {
//        self.maxRequests = maxRequests
//        self.window = window
//    }
//
//    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
//        let ip = request.remoteAddress?.ipAddress ?? "unknown"
//        let now = Date()
//
//        var allowed = true
//        lock.withLock {
//            if var record = clients[ip] {
//                if now > record.resetTime {
//                    record = (1, now.addingTimeInterval(Double(window.nanoseconds) / 1_000_000_000))
//                } else {
//                    record.count += 1
//                }
//                clients[ip] = record
//                if record.count > maxRequests {
//                    allowed = false
//                }
//            } else {
//                clients[ip] = (1, now.addingTimeInterval(Double(window.nanoseconds) / 1_000_000_000))
//            }
//        }
//
//        guard allowed else {
//            throw Abort(.tooManyRequests, reason: "Rate limit exceeded. Try again later.")
//        }
//
//        return try await next.respond(to: request)
//    }
//}
//


import Vapor

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
                return (5, 60)   // 5 requests per 60s for login
            } else {
                return (100, 60) // default global rule
            }
        }()

        let allowed = await store.check(ip: ip, route: route, maxRequests: maxRequests, windowSeconds: windowSeconds)

        guard allowed else {
            throw Abort(.tooManyRequests, reason: "Too many requests to \(route). Try again later.")
        }

        return try await next.respond(to: request)
    }
}
