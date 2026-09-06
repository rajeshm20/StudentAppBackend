# Architecture: Enforce Minimum TLS Version and Configure Cipher Suites

## 1. System Overview & Component Diagram
```text
[ iOS StudyApp / Browser / API Client ]
                 |
          TLS 1.2 / TLS 1.3 (ECDHE-AEAD Ciphers)
                 v
      [ Caddy Reverse Proxy (Optional) ]
                 |
          HTTP / HTTPS
                 v
     [ Vapor SwiftNIO SSL HTTP Server ]
        ├── AppConfig.minimumTLSVersion() -> TLSVersion (.tlsv12 / .tlsv13)
        ├── AppConfig.tlsCipherSuites() -> String (Hardened PFS AEAD ciphers)
        └── configureTLS(app) -> sets app.http.server.configuration.tlsConfiguration
                 |
            Routes & Middleware (SecurityHeaders, RateLimiter, CORS)
                 |
            Controllers & Services (AuthController, StudentController)
                 |
      [ Database Client TLS Layer ]
        └── databaseTLSConfiguration() -> client TLS with minimumTLSVersion = .tlsv12
                 v
            [ MySQL Database Server ]
```

## 2. Layers & Modules Affected
- **Configuration Layer (`Sources/StudentAppBackend/Configure/AppConfig.swift`)**:
  - `AppConfig.minimumTLSVersion(for: Environment) throws -> TLSVersion`
  - `AppConfig.defaultSecureCipherSuites: String`
  - `AppConfig.tlsCipherSuites(for: Environment) -> String`
  - `AppConfig.validateTLSConfiguration(for: Environment) throws`
- **Server Bootstrap Layer (`Sources/StudentAppBackend/Configure/configure.swift`)**:
  - `configureTLS(_ app: Application)`: Applies `minimumTLSVersion` and `cipherSuites` to `TLSConfiguration.makeServerConfiguration(...)`.
  - `databaseTLSConfiguration(for: Environment) -> TLSConfiguration?`: Applies `minimumTLSVersion = .tlsv12` and secure client cipher configuration to client TLS.
- **Edge / Infrastructure Configuration (`Caddyfile`)**:
  - Configures Caddy `tls` block with `protocols tls1.2 tls1.3` and aligned cipher suites for defense-in-depth when Caddy terminates TLS.
- **Test Suite (`Tests/StudentAppBackendTests/StudentAppBackendTests.swift`)**:
  - Unit tests verifying `AppConfig` parsing, version enforcement, rejection of insecure versions, and cipher suite configuration.

## 3. Cryptographic Design & Cipher Suite Hardening
### TLS Protocols:
- Minimum version: `TLSVersion.tlsv12`
- Maximum version: `TLSVersion.tlsv13`
- Deprecated protocols (`.tlsv1`, `.tlsv11`) are strictly rejected.

### Pre-TLS 1.3 Cipher Suites (TLS 1.2):
Configured via OpenSSL/BoringSSL cipher string format:
```text
ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
```
**Cryptographic rationale**:
- **ECDHE**: Mandates Ephemeral Elliptic Curve Diffie-Hellman for Perfect Forward Secrecy (PFS). Session keys cannot be decrypted retrospectively even if the server's private key is compromised.
- **AES-GCM & ChaCha20-Poly1305**: AEAD (Authenticated Encryption with Associated Data) ciphers only. Eliminates MAC-then-Encrypt CBC vulnerabilities (BEAST, Lucky13).
- **Exclusion of Static RSA / DH**: Mitigates key exchange capture attacks.
- **Exclusion of CBC, 3DES, RC4, MD5, SHA-1**: Complies with modern compliance mandates.

### TLS 1.3:
- In BoringSSL / SwiftNIO SSL, TLS 1.3 ciphers (`TLS_AES_128_GCM_SHA256`, `TLS_AES_256_GCM_SHA384`, `TLS_CHACHA20_POLY1305_SHA256`) are automatically negotiated and are all AEAD with PFS.

## 4. Concurrency & Safety
- Pure functional helpers on `AppConfig` with no shared mutable state.
- `TLSVersion` and `TLSConfiguration` are value types (`Sendable`).
- Configuration is evaluated once at startup before accepting network requests.

## 5. Error Handling & Validation
- Setting `TLS_MIN_VERSION` to `1.0` or `1.1` in `.production` triggers a fatal error during `AppConfig.validateProductionSecrets` / `AppConfig.minimumTLSVersion`.
- In non-production environments, unsupported or insecure values fallback to `.tlsv12` with prominent warning logs.
