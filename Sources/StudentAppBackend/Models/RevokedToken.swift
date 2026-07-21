import Fluent
import Vapor

final class RevokedToken: Model, Content, @unchecked Sendable {
    static let schema = "revoked_tokens"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "jti")
    var jti: String

    @Field(key: "expiresAt")
    var expiresAt: Date

    init() {}

    init(id: UUID? = nil, jti: String, expiresAt: Date) {
        self.id = id
        self.jti = jti
        self.expiresAt = expiresAt
    }
}
