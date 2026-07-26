//
//  StudentToken.swift
//  StudentAppBackend
//
//  Created by Rajesh Mani on 07/08/25.
//

@preconcurrency import JWTKit
import Foundation

struct StudentToken: JWTPayload, Sendable {
    var exp: ExpirationClaim
    var studentID: UUID
    var jti: IDClaim

    func verify(using signer: JWTSigner) throws {
        try self.exp.verifyNotExpired()
    }
}
