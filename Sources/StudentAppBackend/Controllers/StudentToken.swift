//
//  StudentToken.swift
//  StudentAppBackend
//
//  Created by Rajesh Mani on 07/08/25.
//

import JWTKit
import Foundation

struct StudentToken: JWTPayload {
    var exp: ExpirationClaim
    var studentID: UUID

    func verify(using signer: JWTSigner) throws {
        try self.exp.verifyNotExpired()
    }
}
