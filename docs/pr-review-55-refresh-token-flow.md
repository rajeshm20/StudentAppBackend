# PR Review Notes — StudentAppBackend #55

## Review Comment 1: Logout does not revoke the active refresh-token family

### Problem
`POST /auth/logout` currently revokes only the current access token JTI and then attempts to revoke a refresh token only if the client sends a body that decodes as `RefreshRequest`.

This means the common request pattern:

```http
POST /auth/logout
Authorization: Bearer <access-token>
```

does not revoke any refresh tokens. The application still allows the user to call `POST /auth/refresh` with the old refresh token, which violates the contract described in the PR.

### Why this happens
The logout handler in `AuthController` is:

```swift
func logout(_ req: Request) async throws -> LogoutResponse {
    _ = try await TokenService.authenticateStudent(from: req)

    guard let payload = req.authenticatedToken else {
        throw Abort(.unauthorized, reason: "Missing or invalid Authorization header")
    }

    try await TokenService.revokeToken(payload, on: req.db)

    if let refreshRequest = try? req.content.decode(RefreshRequest.self) {
        try await tokenService.revokeRefreshToken(rawToken: refreshRequest.refreshToken, on: req.db)
    }

    return LogoutResponse(message: "Logout successful")
}
```

The refresh-token revocation is optional and depends on a decoded request body. That makes logout depend on client behavior rather than on the authenticated user identity.

### Recommended fix
Revoke all refresh tokens for the authenticated student ID, based on the verified JWT payload rather than a request body.

```swift
func logout(_ req: Request) async throws -> LogoutResponse {
    let student = try await TokenService.authenticateStudent(from: req)

    guard let payload = req.authenticatedToken else {
        throw Abort(.unauthorized, reason: "Missing or invalid Authorization header")
    }

    let studentID = try student.requireID()

    try await TokenService.revokeToken(payload, on: req.db)
    try await tokenService.revokeAllSessions(for: studentID, on: req.db)

    return LogoutResponse(message: "Logout successful")
}
```

This should be exposed via `TokenServiceProtocol`:

```swift
func revokeAllSessions(for studentID: UUID, on db: any Database) async throws
```

and implemented in `RefreshTokenRepository` by calling:

```swift
revokeAll(forUserID: userID, on: db)
```

---

## Review Comment 2: Refresh token rotation is vulnerable to race conditions and drift from config

### Problem
The refresh rotation flow currently does not enforce atomic single-use semantics for a refresh token. Two concurrent refresh requests can both read the same record before either one marks it revoked.

The current logic in `TokenService.rotateRefreshToken` is:

```swift
guard let existingToken = try await refreshTokenRepository.find(byHash: tokenHash, on: req.db) else {
    throw Abort(.unauthorized, reason: "Invalid refresh token.")
}

if existingToken.isRevoked {
    try await refreshTokenRepository.revokeAll(forUserID: existingToken.$user.id, on: req.db)
    throw Abort(.unauthorized, reason: "Invalid authentication state. Please log in again.")
}

existingToken.isRevoked = true
try await refreshTokenRepository.update(existingToken, on: req.db)
return try await generateTokenPair(for: student, on: req)
```

This pattern can allow multiple successful rotations for the same refresh token under concurrency.

### Additional issue
The code also hard-codes refresh token expiry to 30 days:

```swift
expiresAt: Date().addingTimeInterval(30 * 86400)
```

but the PR documentation says `JWT_REFRESH_TTL` should be configurable and defaults to 7 days. This creates a mismatch between documented policy and runtime behavior.

### Recommended fix
Use a single transaction / conditional update to guarantee single-use semantics:

- fetch the token row within a DB transaction
- ensure `is_revoked == false`
- atomically mark it revoked
- only issue the new token pair if the update succeeded

Pseudo-implementation:

```swift
try await req.db.transaction { db in
    guard let existingToken = try await refreshTokenRepository.find(byHash: tokenHash, on: db) else {
        throw Abort(.unauthorized, reason: "Invalid refresh token.")
    }

    guard !existingToken.isRevoked else {
        try await refreshTokenRepository.revokeAll(forUserID: existingToken.$user.id, on: db)
        throw Abort(.unauthorized, reason: "Invalid authentication state. Please log in again.")
    }

    guard existingToken.expiresAt > Date() else {
        existingToken.isRevoked = true
        try await refreshTokenRepository.update(existingToken, on: db)
        throw Abort(.unauthorized, reason: "Refresh token has expired.")
    }

    existingToken.isRevoked = true
    try await refreshTokenRepository.update(existingToken, on: db)

    guard let student = try await studentRepository.find(byID: existingToken.$user.id, on: db) else {
        throw Abort(.unauthorized, reason: "Invalid authentication state. User not found.")
    }

    return try await generateTokenPair(for: student, on: req)
}
```

And for expiry, use configuration instead of the hard-coded value:

```swift
let refreshTTL = AppConfig.jwtRefreshTTL()
```

---

## Suggested tests to add before approval

1. Logout without a refresh-token body should still revoke all refresh tokens for the authenticated user.
2. Refreshing the same token twice should yield exactly one successful rotation and one unauthorized response.
3. Concurrent refresh requests using the same token should result in only one successful rotation.
4. Refresh token expiry should match the configured `JWT_REFRESH_TTL` rather than a hard-coded 30-day value.

## Final takeaway
The PR’s overall security direction is good, but the refresh-token lifecycle is not fully enforceable as written. Before merge, the implementation should:

- revoke all refresh tokens on logout using the authenticated user ID,
- enforce single-use rotation atomically, and
- read the refresh expiry from configuration instead of a fixed constant.
