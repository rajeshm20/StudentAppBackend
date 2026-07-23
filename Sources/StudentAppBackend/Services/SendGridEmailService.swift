//
//  EmailSending.swift
//  StudentAppBackend
//
//  Created by Rajesh Mani on 23/07/26.
//


import Vapor
import AsyncHTTPClient

protocol EmailSending: Sendable {
    func send(to email: String, subject: String, body: String) async throws
}

/// SendGrid implementation — swap this out for any provider (Mailgun, SES, Postmark)
/// by conforming to `EmailSending`. Uses SendGrid's HTTP API rather than raw SMTP
/// so we don't need an extra SMTP dependency — Vapor already ships with AsyncHTTPClient.
struct SendGridEmailService: EmailSending {
    let apiKey: String
    let fromEmail: String
    let httpClient: HTTPClient

    func send(to email: String, subject: String, body: String) async throws {
        var request = HTTPClientRequest(url: "https://api.sendgrid.com/v3/mail/send")
        request.method = .POST
        request.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        request.headers.add(name: "Content-Type", value: "application/json")

        let payload: [String: Any] = [
            "personalizations": [["to": [["email": email]]]],
            "from": ["email": fromEmail],
            "subject": subject,
            "content": [["type": "text/plain", "value": body]]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        request.body = .bytes(jsonData)

        let response = try await httpClient.execute(request, timeout: .seconds(10))
        guard (200...299).contains(response.status.code) else {
            throw Abort(.internalServerError, reason: "Failed to send email")
        }
    }
}

/// Local/dev fallback — logs instead of sending, so you don't need a real
/// SendGrid key just to test the flow end-to-end in Docker/WSL.
struct ConsoleEmailService: EmailSending {
    let logger: Logger

    func send(to email: String, subject: String, body: String) async throws {
        logger.notice("📧 [DEV EMAIL] To: \(email) | Subject: \(subject)\n\(body)")
    }
}