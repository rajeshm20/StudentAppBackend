# Feature: Enforce Minimum TLS Version and Configure Cipher Suites

## 1. Problem
Currently, `StudentAppBackend` relies on SwiftNIO SSL default configurations (`TLSConfiguration.makeServerConfiguration(...)` and `TLSConfiguration.makeClientConfiguration()`) for HTTPS and database TLS. In SwiftNIO SSL:
1. The default `minimumTLSVersion` is `.tlsv1` (TLS 1.0). TLS 1.0 and TLS 1.1 have known cryptographic vulnerabilities (e.g., POODLE, BEAST) and are formally deprecated under RFC 8996, PCI DSS 3.2.1+, and NIST SP 800-52r2.
2. The default cipher suites in NIOSSL include legacy, non-forward-secret ciphers (e.g. `RSA+AES` without ephemeral Diffie-Hellman) and CBC mode ciphers.
3. There is no centralized configuration to enforce modern TLS versions (TLS 1.2 minimum, TLS 1.3 preferred) or modern AEAD cipher suites (ECDHE-ECDSA/RSA with AES-GCM or ChaCha20-Poly1305) with environment-based overrides for production hardening and regulatory compliance.

## 2. Goal
1. Enforce TLS 1.2 as the strict minimum version for both the Vapor application server HTTPS listener and the outgoing database TLS connections.
2. Prevent negotiation of deprecated and insecure TLS versions (TLS 1.0, TLS 1.1) under all operational configurations.
3. Configure a hardened, industry-standard list of forward-secret AEAD cipher suites for TLS 1.2 connections (while preserving TLS 1.3 native AEAD cipher suites).
4. Provide structured environment variable configuration (`TLS_MIN_VERSION`, `TLS_CIPHER_SUITES`) managed through `AppConfig` with safe defaults and production validation.
5. Provide aligned reverse proxy TLS hardening guidance in `Caddyfile` for end-to-end defense-in-depth.

## 3. Scope
### In Scope
- Application server TLS configuration in `configureTLS(_ app: Application)` enforcing minimum TLS version (default TLS 1.2) and secure cipher suites.
- Database client TLS configuration in `databaseTLSConfiguration(for: Environment)` enforcing minimum TLS version (TLS 1.2).
- Centralized configuration helpers and validation in `AppConfig` (`minimumTLSVersion()`, `tlsCipherSuites()`, `validateTLSConfiguration()`).
- Reverse proxy TLS hardening in `Caddyfile` enforcing `protocols tls1.2 tls1.3` and secure ciphers.
- Unit and integration tests validating that TLS configurations properly enforce minimum TLS versions and reject downgrade attempts or weak cipher configurations.
- Documentation updates in `.env.example`, `README.md`, and architectural specifications.

### Out of Scope
- Implementation of mTLS (mutual TLS / client certificate verification) for end-users.
- Implementing custom cryptographic algorithms outside of BoringSSL / SwiftNIO SSL.

## 4. Actors
- **Client (iOS StudyApp / Web Browser / API Consumer)**: Initiates TLS handshake to communicate securely with the server.
- **Backend Application Server (Vapor / SwiftNIO SSL)**: Terminating server that negotiates TLS handshake, enforces version boundaries, and selects cipher suites.
- **Database Server (MySQL)**: Receives encrypted client connections from the Vapor backend.
- **Reverse Proxy (Caddy)**: Optional edge reverse proxy terminating external TLS traffic before proxying to Vapor.
- **System Administrator / DevOps**: Configures environment variables (`TLS_MIN_VERSION`, `TLS_CIPHER_SUITES`, `ENABLE_HTTPS`).

## 5. Functional Requirements
- **FR-001**: The application server MUST set `minimumTLSVersion` to at least `.tlsv12` (TLS 1.2) when HTTPS is enabled.
- **FR-002**: The application server MUST support configuring `TLS_MIN_VERSION` to `"1.3"` to strictly enforce TLS 1.3 only.
- **FR-003**: The application server MUST reject or fail startup in production if `TLS_MIN_VERSION` is set to insecure versions (`"1.0"`, `"1.1"`).
- **FR-004**: The application server MUST configure hardened TLS 1.2 cipher suites that mandate Perfect Forward Secrecy (ECDHE) and Authenticated Encryption with Associated Data (AEAD - AES-GCM or ChaCha20-Poly1305).
- **FR-005**: The application server MUST support overriding cipher suites via `TLS_CIPHER_SUITES` environment variable while falling back to secure defaults.
- **FR-006**: Database client TLS connections (`databaseTLSConfiguration`) MUST also enforce `minimumTLSVersion` of at least `.tlsv12`.
- **FR-007**: When `ENABLE_HTTPS` is requested but certificates cannot be loaded, the server behavior MUST adhere to environment rules (fail fast in production, warn in development).

## 6. Non-Functional Requirements
- **NFR-001 (Security)**: Comply with NIST SP 800-52r2, RFC 8996, and OWASP Transport Layer Protection guidelines.
- **NFR-002 (Performance)**: Prefer hardware-accelerated AES-GCM ciphers where available and ChaCha20-Poly1305 for mobile devices without AES instructions. Handshake overhead must not introduce unnecessary latency.
- **NFR-003 (Reliability)**: Zero regressions for non-HTTPS local development and testing environments (SQLite in-memory test suite runs without requiring SSL certificates).
- **NFR-004 (Maintainability)**: TLS logic encapsulated cleanly in `AppConfig` and `configure.swift` with full type safety and structured logging.

## 7. Business Rules
- **BR-001**: Under no circumstances shall TLS 1.0 or TLS 1.1 handshakes be accepted by the application in any environment where TLS is active.
- **BR-002**: In production environment (`environment == .production`), weak TLS configurations must cause immediate startup termination.
- **BR-003**: Default cipher suite list must exclude CBC mode ciphers (preventing Lucky13 / padding oracle attacks) and unauthenticated ciphers (`!aNULL`, `!eNULL`, `!MD5`, `!RC4`, `!3DES`).

## 8. Validation Rules
- **VAL-001**: `TLS_MIN_VERSION` input values accepted: `"1.2"`, `"1.3"`, `"tlsv12"`, `"tlsv13"`, `"tls1.2"`, `"tls1.3"` (case-insensitive).
- **VAL-002**: If `TLS_MIN_VERSION` specifies `"1.0"`, `"1.1"`, `"tlsv1"`, or `"tlsv11"`, `AppConfig` validation MUST throw an error in `.production`, or clamp to `.tlsv12` with a high-severity warning in development.
- **VAL-003**: `TLS_CIPHER_SUITES` must be a colon-delimited string of valid OpenSSL/BoringSSL cipher names.

## 9. API Contract
This feature operates at the transport layer (Layer 4/5) beneath HTTP/REST/GraphQL APIs.
- Existing REST endpoints (`/auth/login`, `/auth/signup/student`, etc.) and GraphQL queries remain unchanged in payload schema.
- Connections attempting handshakes with TLS < 1.2 or non-matching cipher suites will be terminated during TLS handshake (Connection reset / SSL handshake failure) without reaching application HTTP handlers.

## 10. Database Requirements
- No schema, table, or migration changes required.
- MySQL client connection string / `MySQLConfiguration.tlsConfiguration` updated to enforce `minimumTLSVersion = .tlsv12`.

## 11. Security Requirements
- **Protocol Enforceability**: Enforce TLS 1.2 as minimum, TLS 1.3 as maximum supported.
- **Cipher Suite Selection**:
  Hardened default list:
  ```text
  ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
  ```
  Excludes: RC4, 3DES, DES, MD5, SHA-1 MAC suites, static RSA key exchange (`RSA_*`), static Diffie-Hellman (`DH_*`), CBC-mode ciphers (`*_CBC_*`).
- **PFS (Perfect Forward Secrecy)**: All configured ciphers mandate ephemeral key exchange (ECDHE).
- **ALPN**: Support HTTP/1.1 and HTTP/2 (if enabled) negotiations securely.

## 12. Concurrency Requirements
- TLS configuration is initialized during server startup (`configure.swift`) on the main thread/actor before the HTTP server binds ports.
- `TLSConfiguration` in `NIOSSL` is `Sendable`. No shared mutable state is introduced during request handling.

## 13. Error Handling
- **Invalid TLS Version in Production**: Throws `Abort(.internalServerError, reason: "Insecure TLS minimum version configured: ...")`.
- **Missing Certificate / Key in Production**: Throws startup error when `ENABLE_HTTPS=true`.
- **Handshake Failures**: Handled at SwiftNIO channel pipeline level, emitting SSL alert to client and debug logs without crashing event loop.

## 14. Acceptance Criteria
- **AC-001**: Given server HTTPS is configured, when a client initiates a TLS 1.2 or TLS 1.3 handshake with supported ciphers, the connection succeeds.
- **AC-002**: Given server HTTPS is configured, when a client attempts a TLS 1.0 or TLS 1.1 handshake, the connection is rejected at handshake.
- **AC-003**: Given `TLS_MIN_VERSION="1.3"`, the server accepts only TLS 1.3 handshakes and rejects TLS 1.2.
- **AC-004**: Given `TLS_CIPHER_SUITES` configured with custom valid ciphers, the server applies those ciphers.
- **AC-005**: Given database TLS enabled, the client TLS configuration specifies `minimumTLSVersion = .tlsv12`.
- **AC-006**: Default cipher suite list contains only AEAD and PFS ciphers, excluding legacy/CBC ciphers.
- **AC-007**: All unit and integration tests pass cleanly.

## 15. Test Scenarios
### Unit Tests
- `testAppConfigDefaultMinimumTLSVersionIsTLS12`: Verify default is `.tlsv12`.
- `testAppConfigParsesTLS13`: Verify `TLS_MIN_VERSION="1.3"` yields `.tlsv13`.
- `testAppConfigRejectsTLS10InProduction`: Verify setting `TLS_MIN_VERSION="1.0"` throws in production.
- `testAppConfigDefaultCipherSuitesAreHardened`: Verify default cipher suites list contains only AEAD + ECDHE ciphers and no CBC / RSA-static ciphers.
- `testAppConfigCustomCipherSuites`: Verify custom `TLS_CIPHER_SUITES` environment parsing.
- `testDatabaseTLSConfigurationEnforcesTLS12`: Verify `databaseTLSConfiguration` sets `minimumTLSVersion = .tlsv12`.

### Integration Tests
- Server initialization with mock or testing TLS configuration verifies `app.http.server.configuration.tlsConfiguration?.minimumTLSVersion == .tlsv12`.

## 16. Observability
- Server logs the configured minimum TLS version and cipher suite mode at startup at `.notice` level (e.g. `"Configured HTTPS with minimum TLS version: TLS 1.2 and hardened cipher suites"`).
- Startup failure logging if certificate parsing fails.

## 17. Open Questions
- None. Requirements align with industry standards (NIST, RFC 8996, OWASP).

## 18. Assumptions
- Server deployment environment has OpenSSL/BoringSSL capable of TLS 1.2 and TLS 1.3.
- iOS StudyApp (iOS 15+) natively supports TLS 1.2 and TLS 1.3 with standard AEAD cipher suites.
