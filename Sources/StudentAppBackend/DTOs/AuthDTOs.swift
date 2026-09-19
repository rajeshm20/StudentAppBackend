import Vapor

struct TokenPairResponse: Content, Sendable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Int

    init(
        accessToken: String,
        refreshToken: String,
        tokenType: String = "Bearer",
        expiresIn: Int = 900
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
    }
}

struct RefreshRequest: Content, Sendable {
    let refreshToken: String

    init(refreshToken: String) {
        self.refreshToken = refreshToken
    }
}
