//
//  StudentService.swift
//  StudentAppBackend
//
//  Created by Rajesh Mani on 07/08/25.
//


// MARK: - StudentService.swift
import Vapor
import Fluent
import Crypto

struct StudentService {
    static let shared = StudentService()

    func create(student: Student, on db: any Database) async throws {
        student.passwordHash = try Bcrypt.hash(student.passwordHash)
        try await student.save(on: db)
    }

    func authenticate(credentials: Student.LoginRequest, on db: any Database) async throws -> Student? {
        guard let student = try await Student.query(on: db).filter(\.$email == credentials.email).first() else {
            return nil
        }
        guard try Bcrypt.verify(credentials.password, created: student.passwordHash) else {
            return nil
        }
        return student
    }
}
