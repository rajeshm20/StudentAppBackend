import Crypto
import Foundation
import Vapor

public enum PasswordResetSecurity {
    /// Generates a cryptographically secure 6-digit numeric OTP using rejection sampling
    /// over `SystemRandomNumberGenerator` to eliminate modulo bias.
    public static func generateSecureOTP() -> String {
        var generator = SystemRandomNumberGenerator()
        let maxVal: UInt32 = 1_000_000
        let limit = UInt32.max - (UInt32.max % maxVal)
        var num: UInt32
        repeat {
            num = generator.next()
        } while num >= limit
        return String(format: "%06d", num % maxVal)
    }

    /// Generates a 256-bit cryptographically secure URL-safe random session token.
    public static func generateSecureSessionToken() -> String {
        let bytes = [UInt8].random(count: 32)
        return bytes.base64
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Default application secret key for HMAC hashing
    public static func resetSecret() -> String {
        (try? AppConfig.loadPasswordResetSecret(for: .testing)) ?? "studentapp-reset-secret-salt-min-32-chars"
    }

    /// Hashes the 6-digit OTP using HMAC-SHA256 keyed with the application secret
    /// and bound to the normalized user email. This prevents rainbow-table precomputations
    /// on low-entropy numeric codes if a database snapshot is leaked.
    public static func hashOTP(_ code: String, email: String, secret: String? = nil) -> String {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        let message = "\(code):\(normalizedEmail)"
        let effectiveSecret = secret ?? resetSecret()
        let key = SymmetricKey(data: Data(effectiveSecret.utf8))
        let hmac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return hmac.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Hashes the post-verification session token using SHA-256.
    public static func hashSessionToken(_ sessionToken: String) -> String {
        let digest = SHA256.hash(data: Data(sessionToken.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison between two hash strings to prevent timing side-channel attacks.
    public static func constantTimeCompare(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff = 0
        for i in 0..<aBytes.count {
            diff |= Int(aBytes[i] ^ bBytes[i])
        }
        return diff == 0
    }
}
