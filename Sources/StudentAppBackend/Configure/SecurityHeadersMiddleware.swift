//
//  SecurityHeadersMiddleware.swift
//  StudentAppBackend
//
//  Created by Rajesh Mani on 16/08/25.
//

import NIOConcurrencyHelpers
import NIOCore
import Vapor

struct SecurityHeadersMiddleware: AsyncMiddleware {
    private let explicitEnvironment: Environment?

    init(environment: Environment? = nil) {
        self.explicitEnvironment = environment
    }

    /// Determines whether the connection is secure (HTTPS).
    /// Supports direct TLS or trusted reverse-proxy TLS termination (via X-Forwarded-Proto: https).
    static func isSecureConnection(_ request: Request) -> Bool {
        if request.url.scheme?.lowercased() == "https" {
            return true
        }
        if let forwardedProto = request.headers.first(name: .xForwardedProto)?.lowercased(),
            forwardedProto == "https"
        {
            return true
        }
        if let forwardedProto = request.headers.first(name: "X-Forwarded-Proto")?.lowercased(),
            forwardedProto == "https"
        {
            return true
        }
        return false
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response
    {
        let res: Response
        do {
            res = try await next.respond(to: request)
        } catch {
            throw error
        }
        applyHeaders(to: res, for: request)
        return res
    }

    /// Applies security headers to the given response.
    func applyHeaders(to res: Response, for request: Request) {
        let env = explicitEnvironment ?? request.application.environment

        // RFC 6797 §7.2: An HTTP host MUST NOT include the STS header field in HTTP responses
        // conveyed over non-secure transport.
        if Self.isSecureConnection(request),
            let hstsValue = try? AppConfig.hstsHeaderValue(for: env)
        {
            res.headers.replaceOrAdd(name: "Strict-Transport-Security", value: hstsValue)
        } else {
            res.headers.remove(name: "Strict-Transport-Security")
        }

        res.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        res.headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        res.headers.replaceOrAdd(name: "Referrer-Policy", value: "strict-origin-when-cross-origin")
        res.headers.replaceOrAdd(
            name: "Permissions-Policy", value: "geolocation=(), microphone=(), camera=()")
        res.headers.replaceOrAdd(
            name: "Content-Security-Policy",
            value:
                "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:"
        )
    }
}
