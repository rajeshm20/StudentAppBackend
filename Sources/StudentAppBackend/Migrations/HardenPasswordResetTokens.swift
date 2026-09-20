import Fluent
import SQLKit

public struct HardenPasswordResetTokens: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        let dialect = sql.dialect.name.lowercased()
        let driverName = "\(type(of: database))".lowercased()
        let isPostgres = dialect.contains("postgres") || dialect.contains("psql") || driverName.contains("postgres") || driverName.contains("psql")
        let isSQLite = dialect.contains("sqlite") || driverName.contains("sqlite")
        let isMySQL = dialect.contains("mysql") || driverName.contains("mysql")

        if isPostgres {
            try await sql.raw("""
                DO $$
                BEGIN
                    IF NOT EXISTS (
                        SELECT 1 FROM information_schema.columns 
                        WHERE table_name = 'password_reset_tokens' AND column_name = 'code_hash'
                    ) THEN
                        ALTER TABLE password_reset_tokens ADD COLUMN code_hash VARCHAR(255);
                        ALTER TABLE password_reset_tokens ADD COLUMN session_token_hash VARCHAR(255);
                        ALTER TABLE password_reset_tokens ADD COLUMN code_expires_at TIMESTAMP;
                        ALTER TABLE password_reset_tokens ADD COLUMN session_expires_at TIMESTAMP;
                        ALTER TABLE password_reset_tokens ADD COLUMN created_at TIMESTAMP;
                    END IF;
                END $$;
            """).run()

            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_email
                ON password_reset_tokens (email)
            """).run()
            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_code_expires_at
                ON password_reset_tokens (code_expires_at)
            """).run()
            try await sql.raw("""
                CREATE UNIQUE INDEX IF NOT EXISTS idx_password_reset_tokens_session_hash
                ON password_reset_tokens (session_token_hash)
            """).run()
        } else if isMySQL {
            let columns = try await sql.raw("""
                SELECT COLUMN_NAME 
                FROM information_schema.COLUMNS 
                WHERE TABLE_SCHEMA = DATABASE() 
                  AND TABLE_NAME = 'password_reset_tokens' 
                  AND COLUMN_NAME = 'code_hash'
            """).all()

            if columns.isEmpty {
                try await sql.raw("""
                    ALTER TABLE password_reset_tokens 
                    ADD COLUMN code_hash VARCHAR(255) NULL,
                    ADD COLUMN session_token_hash VARCHAR(255) NULL,
                    ADD COLUMN code_expires_at DATETIME NULL,
                    ADD COLUMN session_expires_at DATETIME NULL,
                    ADD COLUMN created_at DATETIME NULL
                """).run()
            }
        } else if isSQLite {
            struct TableColumn: Decodable {
                let name: String
            }
            let info = try await sql.raw("PRAGMA table_info(password_reset_tokens)").all(decoding: TableColumn.self)
            let columnNames = Set(info.map { $0.name })
            if !columnNames.contains("code_hash") {
                try await sql.raw("ALTER TABLE password_reset_tokens ADD COLUMN code_hash TEXT").run()
            }
            if !columnNames.contains("session_token_hash") {
                try await sql.raw("ALTER TABLE password_reset_tokens ADD COLUMN session_token_hash TEXT").run()
            }
            if !columnNames.contains("code_expires_at") {
                try await sql.raw("ALTER TABLE password_reset_tokens ADD COLUMN code_expires_at TEXT").run()
            }
            if !columnNames.contains("session_expires_at") {
                try await sql.raw("ALTER TABLE password_reset_tokens ADD COLUMN session_expires_at TEXT").run()
            }
            if !columnNames.contains("created_at") {
                try await sql.raw("ALTER TABLE password_reset_tokens ADD COLUMN created_at TEXT").run()
            }
            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_email
                ON password_reset_tokens (email)
            """).run()
            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_code_expires_at
                ON password_reset_tokens (code_expires_at)
            """).run()
        }
    }

    public func revert(on database: any Database) async throws {}
}
