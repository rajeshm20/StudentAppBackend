import Vapor

final class JWTAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        _ = try await TokenService.authenticateStudent(from: request)
        return try await next.respond(to: request)
    }
}
