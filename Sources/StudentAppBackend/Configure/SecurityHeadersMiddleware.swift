//
//  SecurityHeadersMiddleware.swift
//  StudentAppBackend
//
//  Created by Rajesh Mani on 16/08/25.
//


import Vapor
import NIOConcurrencyHelpers
import NIOCore

struct SecurityHeadersMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let res = try await next.respond(to: request)

        // ✅ res is a Response, so you can access headers directly
        res.headers.replaceOrAdd(name: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains; preload")
        res.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        res.headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        res.headers.replaceOrAdd(name: "Referrer-Policy", value: "strict-origin-when-cross-origin")
        res.headers.replaceOrAdd(name: "Permissions-Policy", value: "geolocation=(), microphone=(), camera=()")
        res.headers.replaceOrAdd(name: "Content-Security-Policy", value: "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:")

        return res
    }
    
}
