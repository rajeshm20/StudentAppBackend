//
//  CertificateManager.swift
//  StudentAppBackend
//
//  Created by Rajesh Mani on 12/09/26.
//

import Foundation
import Vapor

/// Represents the health and lifecycle status of an X.509 certificate.
enum CertificateStatus: Equatable, Sendable {
    case valid(daysRemaining: Int, expiresAt: String)
    case expiringSoon(daysRemaining: Int, expiresAt: String)
    case expired(expiredAt: String)
    case missing(path: String)
    case invalid(reason: String)

    var isHealthy: Bool {
        if case .valid = self { return true }
        return false
    }

    var requiresRenewal: Bool {
        switch self {
        case .expired, .expiringSoon, .missing:
            return true
        case .valid, .invalid:
            return false
        }
    }
}

/// Service to inspect, validate, and renew self-signed TLS certificates for development.
struct CertificateManager: Sendable {

    /// Inspects the certificate file at the given path and calculates remaining validity days.
    static func checkCertificateStatus(
        certPath: String,
        keyPath: String? = nil,
        thresholdDays: Int = 30
    ) -> CertificateStatus {
        guard FileManager.default.fileExists(atPath: certPath) else {
            return .missing(path: certPath)
        }

        if let keyPath = keyPath, !FileManager.default.fileExists(atPath: keyPath) {
            return .missing(path: keyPath)
        }

        // Fetch expiration date string via openssl
        guard let endDateOutput = runOpenSSL(["x509", "-in", certPath, "-enddate", "-noout"]),
              let rawDate = endDateOutput.split(separator: "=").last?
                  .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .invalid(reason: "Unable to parse certificate expiration date")
        }

        // Check if certificate has already expired
        let expiredCheck = runOpenSSLProcess(["x509", "-in", certPath, "-checkend", "0", "-noout"])
        if expiredCheck != 0 {
            return .expired(expiredAt: rawDate)
        }

        // Check if certificate expires within threshold seconds
        let thresholdSeconds = "\(thresholdDays * 86400)"
        let expiringSoonCheck = runOpenSSLProcess(["x509", "-in", certPath, "-checkend", thresholdSeconds, "-noout"])
        if expiringSoonCheck != 0 {
            // Rough estimation of days remaining
            let daysRemaining = estimateDaysRemaining(certPath: certPath) ?? thresholdDays
            return .expiringSoon(daysRemaining: daysRemaining, expiresAt: rawDate)
        }

        let daysRemaining = estimateDaysRemaining(certPath: certPath) ?? 365
        return .valid(daysRemaining: daysRemaining, expiresAt: rawDate)
    }

    /// Renews development certificates in the specified directory.
    /// Strictly prohibited when environment == .production.
    @discardableResult
    static func renewDevelopmentCertificates(
        certDir: String = "certs",
        days: Int = 365,
        thresholdDays: Int = 30,
        force: Bool = false,
        sans: String = "DNS:localhost,IP:127.0.0.1,IP:::1",
        environment: Environment = .development
    ) throws -> CertificateStatus {
        guard environment != .production else {
            throw Abort(
                .internalServerError,
                reason: "Self-signed certificate auto-renewal is strictly forbidden in production."
            )
        }

        try validateDirectoryPath(certDir)
        try validateSANs(sans)

        let certFile = (certDir as NSString).appendingPathComponent("cert.pem")
        let keyFile = (certDir as NSString).appendingPathComponent("key.pem")

        if !force {
            let currentStatus = checkCertificateStatus(certPath: certFile, keyPath: keyFile, thresholdDays: thresholdDays)
            if case .valid = currentStatus {
                return currentStatus
            }
        }

        try FileManager.default.createDirectory(atPath: certDir, withIntermediateDirectories: true)

        let scriptPath = "scripts/renew-dev-certs.sh"
        let exitCode: Int32

        if FileManager.default.fileExists(atPath: scriptPath) {
            var args = [
                "--cert-dir", certDir,
                "--days", "\(days)",
                "--threshold", "\(thresholdDays)",
                "--san", sans
            ]
            if force {
                args.append("--force")
            }
            exitCode = runProcess(executable: "/bin/bash", arguments: [scriptPath] + args)
        } else {
            // Fallback direct OpenSSL generation if script is not found
            let certExit = runOpenSSLProcess([
                "req", "-x509", "-nodes", "-newkey", "rsa:2048",
                "-keyout", keyFile,
                "-out", certFile,
                "-days", "\(days)",
                "-subj", "/CN=localhost",
                "-addext", "subjectAltName=\(sans)"
            ])
            let p12File = (certDir as NSString).appendingPathComponent("localhost.p12")
            // Export PKCS#12 bundle with empty password for seamless dev/simulator keychain import
            _ = runOpenSSLProcess([
                "pkcs12", "-export",
                "-out", p12File,
                "-inkey", keyFile,
                "-in", certFile,
                "-name", "Vapor Localhost Cert",
                "-passout", "pass:"
            ])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12File)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: certFile)
            exitCode = certExit
        }

        guard exitCode == 0 else {
            throw Abort(
                .internalServerError,
                reason: "Failed to renew development certificates (process exited with code \(exitCode))."
            )
        }

        return checkCertificateStatus(certPath: certFile, keyPath: keyFile, thresholdDays: thresholdDays)
    }

    /// Pre-flight check run during server configuration in non-production environments.
    @discardableResult
    static func ensureDevelopmentCertificates(app: Application) throws -> CertificateStatus {
        guard app.environment != .production else {
            return .valid(daysRemaining: 365, expiresAt: "production-ca")
        }

        let certPath = Environment.get("TLS_CERT") ?? "certs/cert.pem"
        let keyPath = Environment.get("TLS_KEY") ?? "certs/key.pem"
        let certDir = (certPath as NSString).deletingLastPathComponent
        let threshold = AppConfig.devCertRenewalThresholdDays(for: app.environment)
        let autoRenew = AppConfig.autoRenewDevCerts(for: app.environment)

        let status = checkCertificateStatus(certPath: certPath, keyPath: keyPath, thresholdDays: threshold)

        switch status {
        case .valid(let days, let expiresAt):
            app.logger.notice("TLS certificate is healthy (\(days) days remaining, expires: \(expiresAt)).")
            return status

        case .expiringSoon(let days, let expiresAt):
            if autoRenew {
                app.logger.warning("TLS certificate is expiring soon (\(days) days remaining, expires: \(expiresAt)). Auto-renewing...")
                let newStatus = try renewDevelopmentCertificates(certDir: certDir.isEmpty ? "certs" : certDir, thresholdDays: threshold, force: true, environment: app.environment)
                app.logger.notice("TLS certificate auto-renewed successfully.")
                return newStatus
            } else {
                app.logger.warning("TLS certificate expires in \(days) days. Run './scripts/renew-dev-certs.sh' to renew.")
                return status
            }

        case .expired(let expiredAt):
            if autoRenew {
                app.logger.warning("TLS certificate expired on \(expiredAt). Auto-renewing for development...")
                let newStatus = try renewDevelopmentCertificates(certDir: certDir.isEmpty ? "certs" : certDir, thresholdDays: threshold, force: true, environment: app.environment)
                app.logger.notice("TLS certificate auto-renewed successfully.")
                return newStatus
            } else {
                app.logger.error("TLS certificate expired on \(expiredAt). Run './scripts/renew-dev-certs.sh' to renew.")
                return status
            }

        case .missing(let path):
            if autoRenew {
                app.logger.notice("TLS certificate not found at '\(path)'. Generating new self-signed certificate...")
                let newStatus = try renewDevelopmentCertificates(certDir: certDir.isEmpty ? "certs" : certDir, thresholdDays: threshold, force: true, environment: app.environment)
                app.logger.notice("TLS certificate generated successfully.")
                return newStatus
            } else {
                app.logger.warning("TLS certificate missing at '\(path)'. Run './scripts/renew-dev-certs.sh' to generate.")
                return status
            }

        case .invalid(let reason):
            app.logger.error("TLS certificate at '\(certPath)' is invalid: \(reason).")
            return status
        }
    }

    // MARK: - Path and Input Validation

    private static func validateDirectoryPath(_ path: String) throws {
        guard !path.contains("..") else {
            throw Abort(.badRequest, reason: "Invalid certificate directory: directory traversal '..' is forbidden.")
        }
        guard !path.contains("\0") else {
            throw Abort(.badRequest, reason: "Invalid certificate directory: null bytes are forbidden.")
        }
        let sensitiveDirs = ["/", "/etc", "/dev", "/sys", "/proc", "/bin", "/usr", "/sbin"]
        for dir in sensitiveDirs {
            if path == dir || path.hasPrefix(dir + "/") {
                throw Abort(.forbidden, reason: "Invalid certificate directory: targeting sensitive system directory '\(path)' is forbidden.")
            }
        }
    }

    private static func validateSANs(_ sans: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:,-")
        guard sans.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw Abort(.badRequest, reason: "Invalid SANs: only alphanumeric, commas, dots, colons, hyphens, and underscores are allowed.")
        }
    }

    // MARK: - Process Execution Helpers

    private static func runOpenSSL(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func runOpenSSLProcess(_ arguments: [String]) -> Int32 {
        runProcess(executable: "/usr/bin/openssl", arguments: arguments)
    }

    private static func runProcess(executable: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private static func estimateDaysRemaining(certPath: String) -> Int? {
        // Test intervals: 1 day, 7 days, 14 days, 30 days, 60 days, 90 days, 180 days, 365 days
        let dayIntervals = [1, 7, 14, 30, 60, 90, 180, 270, 365]
        for days in dayIntervals {
            let seconds = "\(days * 86400)"
            if runOpenSSLProcess(["x509", "-in", certPath, "-checkend", seconds, "-noout"]) != 0 {
                return days
            }
        }
        return 365
    }
}
