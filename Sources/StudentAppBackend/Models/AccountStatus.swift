// MARK: - AccountStatus.swift
// Account lifecycle status.
// Authentication must verify status before granting access.

import Vapor

/// Represents the lifecycle status of a user account.
///
/// The raw string value is persisted to the database column `status`.
/// Authentication is only permitted for `.active` accounts.
enum AccountStatus: String, Codable, Content {
    /// Account is active and authentication is permitted.
    case active     = "active"

    /// Account exists but has been deactivated. Login rejected.
    case inactive   = "inactive"

    /// Account has been administratively suspended. Login rejected.
    case suspended  = "suspended"

    /// Account registration is complete but pending admin approval. Login rejected.
    case pending    = "pending"

    /// Whether authentication should be permitted for this status.
    var isLoginPermitted: Bool {
        return self == .active
    }
}
