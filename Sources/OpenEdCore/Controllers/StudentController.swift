// MARK: - StudentController.swift
// Student resource endpoints with role-based and resource-level authorization.
// Authentication (JWTAuthMiddleware) must be applied before these handlers run.
// Authorization is enforced via AuthorizationService — not inline role checks.

import Vapor
import Fluent

struct StudentController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // All student resource routes require authentication
        let protected = routes.grouped(JWTAuthMiddleware())
        let students = protected.grouped("students")

        students.get(":studentID", use: getStudent)
    }

    // MARK: - GET /students/:studentID

    /// Retrieves a student record.
    ///
    /// Authorization policy (enforced by AuthorizationService):
    ///   - ADMIN     → any student
    ///   - PRINCIPAL → any student (future: school-scoped)
    ///   - TEACHER   → any student (future: class-scoped)
    ///   - STUDENT   → own record only (strict IDOR prevention)
    func getStudent(_ req: Request) async throws -> Student.Public {
        let requester = try await TokenService.authenticateStudent(from: req)

        guard let studentIDParam = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid student ID format")
        }

        // Authorization check — must happen before data fetch
        guard AuthorizationService.canAccessStudentRecord(requester: requester, targetStudentID: studentIDParam) else {
            // Return 403 Forbidden — not 404 — so the client knows they are authenticated
            // but not authorized (vs. the resource not existing at all)
            throw Abort(.forbidden, reason: "You are not authorized to access this student record")
        }

        guard let student = try await Student.find(studentIDParam, on: req.db) else {
            throw Abort(.notFound, reason: "Student not found")
        }

        return student.convertToPublic()
    }
}
