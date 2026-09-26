import Vapor
import Fluent

final class RefreshToken: Model, Content, @unchecked Sendable {
    static let schema = "refresh_tokens"

    @ID(key: .id)
    var id: UUID?

    /// SHA-256 hash of the plain-text token presented to the client
    @Field(key: "token_hash")
    var tokenHash: String

    @Parent(key: "user_id")
    var user: Student

    @Field(key: "expires_at")
    var expiresAt: Date

    @Field(key: "is_revoked")
    var isRevoked: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tokenHash: String,
        userID: Student.IDValue,
        expiresAt: Date,
        isRevoked: Bool = false
    ) {
        self.id = id
        self.tokenHash = tokenHash
        self.$user.id = userID
        self.expiresAt = expiresAt
        self.isRevoked = isRevoked
    }
}
