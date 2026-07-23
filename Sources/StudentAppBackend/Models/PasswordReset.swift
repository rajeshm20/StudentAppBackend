//
//  File.swift
//  StudentAppBackend
//
//  Created by Rajesh Mani on 23/07/26.
//

import Foundation
import Vapor

struct ForgotPasswordRequest: Content {
    let email: String
}

struct ForgotPasswordResponse: Content {
    let success: Bool
    let message: String
    // No token here anymore — it goes out via email only.
}

struct VerifyResetCodeRequest: Content {
    let email: String
    let code: String
}

struct VerifyResetCodeResponse: Content {
    let success: Bool
    let message: String
    let sessionToken: String?   // short-lived, only returned once the code is confirmed
}

struct ResetPasswordRequest: Content {
    let email: String
    let sessionToken: String
    let newPassword: String
    let confirmPassword: String
}

struct ResetPasswordResponse: Content {
    let success: Bool
    let message: String
}
