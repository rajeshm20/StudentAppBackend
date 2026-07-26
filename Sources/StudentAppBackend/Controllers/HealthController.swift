import Fluent
import SQLKit
import Vapor

struct HealthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("health", "live", use: live)
        routes.get("health", "ready", use: ready)
    }

    func live(_ req: Request) -> HealthResponse {
        HealthResponse(status: "ok")
    }

    func ready(_ req: Request) async throws -> Response {
        guard let sql = req.db as? any SQLDatabase else {
            throw Abort(.serviceUnavailable, reason: "Database unavailable")
        }

        do {
            try await sql.raw("SELECT 1").run()
        } catch {
            req.logger.error("Readiness check failed: \(error)")
            throw Abort(.serviceUnavailable, reason: "Database not ready")
        }

        let response = Response(status: .ok)
        try response.content.encode(HealthResponse(status: "ready"))
        return response
    }
}

struct HealthResponse: Content {
    let status: String
}
