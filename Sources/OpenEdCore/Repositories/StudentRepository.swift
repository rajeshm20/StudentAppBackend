import Fluent
import Foundation
import Vapor

protocol StudentRepository: Sendable {
    func find(byID id: UUID, on db: any Database) async throws -> Student?
    func find(byEmail email: String, on db: any Database) async throws -> Student?
    func find(byContactNumber contactNumber: String, on db: any Database) async throws -> Student?
    func all(on db: any Database) async throws -> [Student]
    func create(_ student: Student, on db: any Database) async throws
    func update(_ student: Student, on db: any Database) async throws
}

struct DatabaseStudentRepository: StudentRepository {
    init() {}

    func find(byID id: UUID, on db: any Database) async throws -> Student? {
        try await Student.find(id, on: db)
    }

    func find(byEmail email: String, on db: any Database) async throws -> Student? {
        try await Student.query(on: db)
            .filter(\.$email == email)
            .first()
    }

    func find(byContactNumber contactNumber: String, on db: any Database) async throws -> Student? {
        try await Student.query(on: db)
            .filter(\.$contactNumber == contactNumber)
            .first()
    }

    func all(on db: any Database) async throws -> [Student] {
        try await Student.query(on: db).all()
    }

    func create(_ student: Student, on db: any Database) async throws {
        try await student.save(on: db)
    }

    func update(_ student: Student, on db: any Database) async throws {
        try await student.save(on: db)
    }
}
