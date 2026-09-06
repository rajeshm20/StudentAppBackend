// MARK: - RoleMiddleware.swift
// Centralized role-based access control middleware.
// Must be chained AFTER JWTAuthMiddleware (which populates request.authenticatedRole).
//
// Usage:
//   let adminRoutes = protectedRoutes.grouped(RoleMiddleware(roles: .admin))
//   let schoolAdminRoutes = protectedRoutes.grouped(RoleMiddleware(roles: .admin, .principal))
//
// Never scatter `if user.role == "admin"` checks throughout controllers.
// Define access at the routing layer using this middleware.

import Vapor

final class RoleMiddleware: AsyncMiddleware {
    // MARK: - Configuration

    private let requiredRoles: Set<UserRole>

    /// Initialize with one or more roles that are permitted to access protected routes.
    init(roles: UserRole...) {
        self.requiredRoles = Set(roles)
    }

    // MARK: - AsyncMiddleware

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let role = request.authenticatedRole else {
            // JWTAuthMiddleware was not applied upstream — configuration error
            throw Abort(.unauthorized, reason: "Authentication required")
        }

        guard requiredRoles.contains(role) else {
            // Authenticated but insufficient privileges
            request.logger.warning(
                "Authorization denied",
                metadata: [
                    "role": .string(role.rawValue),
                    "requiredRoles": .string(requiredRoles.map(\.rawValue).sorted().joined(separator: ","))
                ]
            )
            throw Abort(.forbidden, reason: "Insufficient permissions for this operation")
        }

        return try await next.respond(to: request)
    }
}
