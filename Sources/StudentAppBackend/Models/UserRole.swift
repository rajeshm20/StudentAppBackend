// MARK: - UserRole.swift
// Strongly-typed user role.
// Add new roles here as new cases; the raw string is persisted to the database.
// Do NOT use string literals for role comparisons — always use this enum.

import Vapor

/// Represents the authorization role assigned to every user account.
///
/// The raw string value is persisted to the database column `role`.
/// New roles can be introduced by adding new cases; no migration is required
/// for the enum itself (the DB column stores a VARCHAR).
enum UserRole: String, Codable, CaseIterable, Content {
    case admin      = "admin"
    case principal  = "principal"
    case teacher    = "teacher"
    case student    = "student"

    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .admin:     return "Administrator"
        case .principal: return "Principal"
        case .teacher:   return "Teacher"
        case .student:   return "Student"
        }
    }

    /// Whether this role has full system access.
    var isSystemAdmin: Bool { self == .admin }

    /// Whether this role has school-level administrative access.
    var isSchoolAdmin: Bool { self == .admin || self == .principal }

    /// Whether this role is privileged (cannot be assigned via public signup).
    var isPrivileged: Bool {
        switch self {
        case .admin, .principal, .teacher: return true
        case .student: return false
        }
    }
}
