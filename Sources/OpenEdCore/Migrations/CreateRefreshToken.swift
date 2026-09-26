import Fluent
import SQLKit

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

        if let sql = database as? any SQLDatabase {
            let dialect = sql.dialect.name.lowercased()
            let driverName = "\(type(of: database))".lowercased()
            let isPostgres = dialect.contains("postgres") || dialect.contains("psql") || driverName.contains("postgres") || driverName.contains("psql")
            let isSQLite = dialect.contains("sqlite") || driverName.contains("sqlite")
            let isMySQL = dialect.contains("mysql") || driverName.contains("mysql")

            if isPostgres || isSQLite {
                try await sql.raw("""
                    CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user_id
                    ON refresh_tokens (user_id)
                """).run()
                try await sql.raw("""
                    CREATE INDEX IF NOT EXISTS idx_refresh_tokens_expires_at
                    ON refresh_tokens (expires_at)
                """).run()
            } else if isMySQL {
                try await sql.raw("""
                    ALTER TABLE refresh_tokens
                    ADD INDEX idx_refresh_tokens_user_id (`user_id`)
                """).run()
                try await sql.raw("""
                    ALTER TABLE refresh_tokens
                    ADD INDEX idx_refresh_tokens_expires_at (`expires_at`)
                """).run()
            }
        }
    }

    public func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            let dialect = sql.dialect.name.lowercased()
            let driverName = "\(type(of: database))".lowercased()
            let isPostgres = dialect.contains("postgres") || dialect.contains("psql") || driverName.contains("postgres") || driverName.contains("psql")
            let isSQLite = dialect.contains("sqlite") || driverName.contains("sqlite")
            let isMySQL = dialect.contains("mysql") || driverName.contains("mysql")

            if isPostgres || isSQLite {
                try await sql.raw("DROP INDEX IF EXISTS idx_refresh_tokens_user_id").run()
                try await sql.raw("DROP INDEX IF EXISTS idx_refresh_tokens_expires_at").run()
            } else if isMySQL {
                try await sql.raw("ALTER TABLE refresh_tokens DROP INDEX idx_refresh_tokens_user_id").run()
                try await sql.raw("ALTER TABLE refresh_tokens DROP INDEX idx_refresh_tokens_expires_at").run()
            }
        }
        try await database.schema(RefreshToken.schema).delete()
    }
}
