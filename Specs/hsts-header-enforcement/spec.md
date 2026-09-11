# Feature: Add HSTS Header to All HTTPS Responses

## 1. Problem
HTTP Strict Transport Security (HSTS, defined in RFC 6797) is a critical security mechanism that forces user agents (browsers, HTTP clients, mobile applications) to communicate with a host exclusively over encrypted HTTPS connections. Without strict HSTS configuration:
1. **Downgrade / SSL-Stripping Attacks**: An adversary conducting a Man-in-the-Middle (MITM) attack can intercept an unencrypted HTTP redirect or request and prevent the client from ever upgrading to HTTPS.
2. **RFC 6797 §7.2 Violations**: Unconditionally emitting HSTS headers over unencrypted HTTP is an RFC violation. An attacker on an insecure network could inject spoofed HSTS headers with malicious directives or long durations to cause denial of service.
3. **Error Response Header Leakage**: When security middleware is placed behind error-handling middleware or fails to handle errors, HTTP error responses (400, 401, 403, 404, 429, 500) omit security headers, leaving clients exposed even during error interactions.
4. **Lack of Centralized Configuration**: Hardcoded HSTS headers prevent staging or canary environments from testing shorter max-age durations before committing to long-term HSTS preload list requirements.

## 2. Goal
1. Enforce HSTS (`Strict-Transport-Security`) on **all** responses served over HTTPS (both direct TLS and trusted reverse proxy termination).
2. Strictly comply with RFC 6797 §7.2 by suppressing `Strict-Transport-Security` when a response is conveyed over plain, unencrypted HTTP.
3. Guarantee that all error responses (4xx and 5xx) retain the HSTS header when delivered over HTTPS.
4. Centralize HSTS settings in `AppConfig` with environment variable overrides (`HSTS_ENABLED`, `HSTS_MAX_AGE`, `HSTS_INCLUDE_SUBDOMAINS`, `HSTS_PRELOAD`).
5. Configure reverse proxy defense-in-depth in `Caddyfile` for edge TLS termination.
6. Provide comprehensive automated unit and integration tests verifying HSTS injection, suppression, error handling, and configuration overrides.

## 3. Scope
### In Scope
- `AppConfig`: Configuration helpers for HSTS max-age, includeSubDomains, preload, and enable toggle, plus production validation.
- `SecurityHeadersMiddleware`: Transport security inspection (`isSecureConnection`), RFC 6797 compliance, and header injection.
- `configure.swift`: Pipeline registration at `.beginning` ensuring error responses retain security headers.
- `Caddyfile`: Reverse proxy edge HSTS declaration.
- Documentation: `.env.example`, `README.md`, and specifications.
- Test Suite: Comprehensive test cases validating HTTPS presence, HTTP omission, error response persistence, and custom configurations.

### Out of Scope
- Automatic domain submission to the official Chrome HSTS Preload list (this is an administrative process at hstspreload.org).
- HPKP (Public Key Pinning - deprecated across modern browsers).

## 4. Actors
- **Client (iOS StudyApp / Web Browser / API Consumer)**: Receives and caches the HSTS policy for the domain.
- **Backend Application Server (Vapor)**: Evaluates connection security and attaches HSTS and security headers.
- **Reverse Proxy (Caddy)**: Terminates TLS, injects edge HSTS, and forwards `X-Forwarded-Proto: https` to Vapor.
- **System Administrator / DevOps**: Controls environment configuration parameters.

## 5. Functional Requirements
- **FR-001**: The server MUST attach the `Strict-Transport-Security` header to all HTTP responses when the connection is secure (direct HTTPS or `X-Forwarded-Proto: https`).
- **FR-002**: The server MUST NOT attach the `Strict-Transport-Security` header to HTTP responses conveyed over unencrypted transport (RFC 6797 §7.2).
- **FR-003**: The server MUST include `Strict-Transport-Security` on all HTTPS error responses (including 400, 401, 403, 404, 429, and 500).
- **FR-004**: The default HSTS header value MUST be `max-age=63072000; includeSubDomains; preload` (2 years, meeting HSTS preload requirements).
- **FR-005**: The server MUST support configuring `HSTS_MAX_AGE` with non-negative integer values.
- **FR-006**: The server MUST support toggling `includeSubDomains` via `HSTS_INCLUDE_SUBDOMAINS` (default: true).
- **FR-007**: The server MUST support toggling `preload` via `HSTS_PRELOAD` (default: true).
- **FR-008**: The server MUST support disabling HSTS via `HSTS_ENABLED=false` for specialized local testing environments.
- **FR-009**: Baseline security headers (`X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy`, `Content-Security-Policy`) MUST remain present on all responses regardless of transport protocol.

## 6. Non-Functional Requirements
- **NFR-001 (Security)**: Full adherence to RFC 6797 and OWASP Secure Headers Project guidelines.
- **NFR-002 (Performance)**: Transport check and header injection must introduce negligible overhead (< 0.1ms).
- **NFR-003 (Reliability)**: Zero regressions for local development, CI test suites, and Docker containerized deployments.

## 7. Business & Validation Rules
- **BR-001**: In production, `HSTS_MAX_AGE` must not be set to a negative number.
- **BR-002**: If `HSTS_ENABLED` is false, no `Strict-Transport-Security` header shall be emitted.
- **VAL-001**: `HSTS_MAX_AGE` must parse to a valid non-negative integer or fail with a 500 Internal Server Error configuration abort.
- **VAL-002**: Boolean environment flags (`HSTS_ENABLED`, `HSTS_INCLUDE_SUBDOMAINS`, `HSTS_PRELOAD`) accept standard truthy/falsy values (`true`/`false`, `1`/`0`, `yes`/`no`).
