import Vapor

struct APIErrorPayload: Content, Sendable {
    struct ErrorDetail: Content, Sendable {
        let code: String
        let message: String
        let timestamp: String
    }
    let error: ErrorDetail
}

final class UnifiedErrorMiddleware: AsyncMiddleware {
    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            let status: HTTPStatus
            let reason: String
            let code: String

            if let abort = error as? (any AbortError) {
                status = abort.status
                reason = abort.reason
                if let debuggable = error as? (any DebuggableError),
                   !debuggable.identifier.isEmpty,
                   debuggable.identifier != "\(abort.status.code)" {
                    code = debuggable.identifier
                } else {
                    code = defaultCode(for: abort.status)
                }
            } else {
                status = .internalServerError
                reason = environment == .production ? "An internal error occurred." : String(describing: error)
                code = "INTERNAL_SERVER_ERROR"
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let timestamp = formatter.string(from: Date())

            let payload = APIErrorPayload(
                error: .init(
                    code: code,
                    message: reason,
                    timestamp: timestamp
                )
            )

            let response = Response(status: status)
            response.headers.contentType = .json
            try response.content.encode(payload)
            return response
        }
    }

    private func defaultCode(for status: HTTPStatus) -> String {
        switch status {
        case .badRequest: return "BAD_REQUEST"
        case .unauthorized: return "UNAUTHORIZED"
        case .forbidden: return "FORBIDDEN"
        case .notFound: return "NOT_FOUND"
        case .conflict: return "CONFLICT"
        case .tooManyRequests: return "TOO_MANY_REQUESTS"
        default: return "ERROR_\(status.code)"
        }
    }
}
