// MARK: - AuthorizationService.swift
// Centralized resource-level authorization.
// Separates authentication (who are you?) from authorization (what can you do?).
//
// This service answers policy questions beyond role checking:
//   - Can this authenticated user access THIS specific student record?
//   - Is this user authorized to manage teachers?
//
// Avoids IDOR/BOLA by ensuring authenticated users can only access
// resources they are authorized to see, not just any resource by ID.

import Vapor
import Fluent

enum AuthorizationService {
    // MARK: - Student Record Access

    /// Determines whether a requester can read a specific student record.
    ///
    /// Policy:
    ///   - ADMIN → any student
    ///   - PRINCIPAL → any student (future: scoped to their school)
    ///   - TEACHER → any student (future: scoped to their assigned classes)
    ///   - STUDENT → only their own record
    ///
    /// - Parameters:
    ///   - requester: The authenticated user making the request
    ///   - targetStudentID: The UUID of the student record being requested
    /// - Returns: true if access is permitted
    static func canAccessStudentRecord(requester: Student, targetStudentID: UUID) -> Bool {
        switch requester.role {
        case .admin:
            return true
        case .principal:
            // Future: enforce school-scoped check (requester.schoolId == target.schoolId)
            return true
        case .teacher:
            // Future: enforce class-scoped check
            return true
        case .student:
            // Students can only view their own record — strict IDOR prevention
            return requester.id == targetStudentID
        }
    }

    /// Determines whether the requester can manage (create/modify/delete) teacher accounts.
    ///
    /// Policy: ADMIN and PRINCIPAL can manage teachers.
    static func canManageTeachers(requester: Student) -> Bool {
        return requester.role == .admin || requester.role == .principal
    }

    /// Determines whether the requester can manage student accounts.
    ///
    /// Policy: ADMIN and PRINCIPAL can manage any student.
    ///         TEACHER cannot manage students.
    ///         STUDENT cannot manage any student.
    static func canManageStudents(requester: Student) -> Bool {
        return requester.role == .admin || requester.role == .principal
    }

    /// Determines whether the requester can perform system-level administrative operations.
    ///
    /// Policy: ADMIN only.
    static func canPerformSystemAdminOperations(requester: Student) -> Bool {
        return requester.role == .admin
    }

    // MARK: - RBAC Helpers for GraphQL Resolvers

    /// Returns the set of student records accessible to the given requester.
    ///
    /// Used by GraphQL `students` query to prevent leaking records the requester cannot see.
    static func filterAccessibleStudents(
        requester: Student,
        allStudents: [Student]
    ) -> [Student] {
        switch requester.role {
        case .admin:
            return allStudents
        case .principal:
            // Future: filter by school
            return allStudents
        case .teacher:
            // Future: filter by assigned classes
            return allStudents
        case .student:
            // Students can only see themselves
            return allStudents.filter { $0.id == requester.id }
        }
    }
}
