// MARK: - JWTAuthMiddleware.swift
// Verifies the JWT bearer token and populates the request authentication context.
// After this middleware runs, `request.authenticatedStudent` and `request.authenticatedRole`
// are available to downstream handlers.
// Use `RoleMiddleware` in addition to this middleware to enforce role-based access control.

import Vapor

final class JWTAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // authenticateStudent also sets request.authenticatedRole from the JWT claim
        _ = try await TokenService.authenticateStudent(from: request)
        return try await next.respond(to: request)
    }
}
