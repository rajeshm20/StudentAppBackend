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
            // 1. Add new columns if missing
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

            // 2. Invalidate any existing reset token rows to remediate legacy plaintext secrets
            try await sql.raw("UPDATE password_reset_tokens SET used = true WHERE used = false;").run()

            // 3. Drop legacy plaintext and obsolete columns
            try await sql.raw("""
                ALTER TABLE password_reset_tokens DROP COLUMN IF EXISTS code;
                ALTER TABLE password_reset_tokens DROP COLUMN IF EXISTS "sessionToken";
                ALTER TABLE password_reset_tokens DROP COLUMN IF EXISTS session_token;
                ALTER TABLE password_reset_tokens DROP COLUMN IF EXISTS "codeExpiresAt";
                ALTER TABLE password_reset_tokens DROP COLUMN IF EXISTS "sessionExpiresAt";
            """).run()

            // 4. Create lookup and unique indexes
            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_email
                ON password_reset_tokens (email);
            """).run()
            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_code_expires_at
                ON password_reset_tokens (code_expires_at);
            """).run()
            try await sql.raw("""
                CREATE UNIQUE INDEX IF NOT EXISTS idx_password_reset_tokens_session_hash
                ON password_reset_tokens (session_token_hash);
            """).run()

        } else if isMySQL {
            // 1. Add new columns if missing
            let hashColumns = try await sql.raw("""
                SELECT COLUMN_NAME 
                FROM information_schema.COLUMNS 
                WHERE TABLE_SCHEMA = DATABASE() 
                  AND TABLE_NAME = 'password_reset_tokens' 
                  AND COLUMN_NAME = 'code_hash'
            """).all()

            if hashColumns.isEmpty {
                try await sql.raw("""
                    ALTER TABLE password_reset_tokens 
                    ADD COLUMN code_hash VARCHAR(255) NULL,
                    ADD COLUMN session_token_hash VARCHAR(255) NULL,
                    ADD COLUMN code_expires_at DATETIME NULL,
                    ADD COLUMN session_expires_at DATETIME NULL,
                    ADD COLUMN created_at DATETIME NULL
                """).run()
            }

            // 2. Invalidate any existing reset token rows
            try await sql.raw("UPDATE password_reset_tokens SET used = 1 WHERE used = 0;").run()

            // 3. Drop legacy plaintext and obsolete columns if they exist
            struct MySQLCol: Decodable {
                let column_name: String
                enum CodingKeys: String, CodingKey {
                    case column_name = "COLUMN_NAME"
                }
            }
            let existingColumns = try await sql.raw("""
                SELECT COLUMN_NAME 
                FROM information_schema.COLUMNS 
                WHERE TABLE_SCHEMA = DATABASE() 
                  AND TABLE_NAME = 'password_reset_tokens'
            """).all(decoding: MySQLCol.self)
            let colNames = Set(existingColumns.map { $0.column_name.lowercased() })

            if colNames.contains("code") {
                try await sql.raw("ALTER TABLE password_reset_tokens DROP COLUMN code").run()
            }
            if colNames.contains("sessiontoken") {
                try await sql.raw("ALTER TABLE password_reset_tokens DROP COLUMN sessionToken").run()
            }
            if colNames.contains("codeexpiresat") {
                try await sql.raw("ALTER TABLE password_reset_tokens DROP COLUMN codeExpiresAt").run()
            }
            if colNames.contains("sessionexpiresat") {
                try await sql.raw("ALTER TABLE password_reset_tokens DROP COLUMN sessionExpiresAt").run()
            }

            // 4. Create lookup and unique indexes if missing
            struct MySQLIdx: Decodable {
                let index_name: String
                enum CodingKeys: String, CodingKey {
                    case index_name = "INDEX_NAME"
                }
            }
            let existingIndexes = try await sql.raw("""
                SELECT INDEX_NAME 
                FROM information_schema.STATISTICS 
                WHERE TABLE_SCHEMA = DATABASE() 
                  AND TABLE_NAME = 'password_reset_tokens'
            """).all(decoding: MySQLIdx.self)
            let idxNames = Set(existingIndexes.map { $0.index_name })

            if !idxNames.contains("idx_password_reset_tokens_email") {
                try await sql.raw("ALTER TABLE password_reset_tokens ADD INDEX idx_password_reset_tokens_email (`email`)").run()
            }
            if !idxNames.contains("idx_password_reset_tokens_code_expires_at") {
                try await sql.raw("ALTER TABLE password_reset_tokens ADD INDEX idx_password_reset_tokens_code_expires_at (`code_expires_at`)").run()
            }
            if !idxNames.contains("idx_password_reset_tokens_session_hash") {
                try await sql.raw("ALTER TABLE password_reset_tokens ADD UNIQUE INDEX idx_password_reset_tokens_session_hash (`session_token_hash`)").run()
            }

        } else if isSQLite {
            struct TableColumn: Decodable {
                let name: String
            }
            let info = try await sql.raw("PRAGMA table_info(password_reset_tokens)").all(decoding: TableColumn.self)
            let columnNames = Set(info.map { $0.name })

            // 1. Add new columns if missing
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

            // 2. Invalidate any existing reset token rows
            try await sql.raw("UPDATE password_reset_tokens SET used = 1 WHERE used = 0;").run()

            // 3. Drop legacy plaintext and obsolete columns if they exist
            if columnNames.contains("code") {
                try await sql.raw("ALTER TABLE password_reset_tokens DROP COLUMN code").run()
            }
            if columnNames.contains("sessionToken") {
                try await sql.raw("ALTER TABLE password_reset_tokens DROP COLUMN sessionToken").run()
            }
            if columnNames.contains("codeExpiresAt") {
                try await sql.raw("ALTER TABLE password_reset_tokens DROP COLUMN codeExpiresAt").run()
            }
            if columnNames.contains("sessionExpiresAt") {
                try await sql.raw("ALTER TABLE password_reset_tokens DROP COLUMN sessionExpiresAt").run()
            }

            // 4. Create lookup and unique indexes
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
        }
    }

    public func revert(on database: any Database) async throws {}
}
