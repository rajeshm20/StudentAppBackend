import Fluent

public struct CreateRefreshToken: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(RefreshToken.schema)
            .id()
            .field("token_hash", .string, .required)
            .field("user_id", .uuid, .required, .references("students", "id", onDelete: .cascade))
            .field("expires_at", .datetime, .required)
            .field("is_revoked", .bool, .required)
            .field("created_at", .datetime)
            .unique(on: "token_hash")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(RefreshToken.schema).delete()
    }
}
