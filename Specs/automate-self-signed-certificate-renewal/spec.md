# Feature: Automate Self-Signed Certificate Renewal for Development

## 1. Problem
In `StudentAppBackend`, local development over HTTPS relies on self-signed X.509 certificates located in `certs/` (`cert.pem`, `key.pem`, and `localhost.p12`).
1. **Certificate Expiration Outages**: Self-signed certificates generated for development expire after 365 days. When they expire, local HTTPS requests fail with SSL errors (e.g. `SSL: CERTIFICATE_VERIFY_FAILED`, `ERR_CERT_DATE_INVALID`), blocking frontend (iOS/web) and backend testing.
2. **Setup Friction**: New developers setting up on fresh machines or CI environments without pre-generated certificates face startup failures when `ENABLE_HTTPS=true` is requested.
3. **Manual Overhead & Non-Standard Generation**: Developers currently follow manual OpenSSL CLI instructions in the README. Inconsistent commands often omit modern Subject Alternative Names (`subjectAltName = DNS:localhost, IP:127.0.0.1, IP:::1`), causing modern browsers and iOS HTTP clients to reject the certificates.
4. **No Automated Health or Pre-Flight Checks**: The server has no automated mechanism in development to detect that certificates are near expiration or to automatically refresh them before developer disruption occurs.

## 2. Goal
1. Provide an automated, cross-platform CLI tool (`scripts/renew-dev-certs.sh`) to inspect, generate, and renew development certificates.
2. Provide an application-level `CertificateManager` service that checks certificate status on startup in non-production environments and auto-renews when enabled.
3. Enforce modern Subject Alternative Names (`DNS:localhost, IP:127.0.0.1, IP:::1`) and secure file permissions (`0600` for keys and PKCS#12 bundles, `0644` for public certs).
4. Strictly protect production environments (`.production`) by preventing self-signed certificate generation or auto-renewal, requiring trusted CA / ACME certificates.
5. Provide comprehensive automated unit and integration tests verifying inspection, renewal, and security boundaries.

## 3. Scope
### In Scope
- Shell automation tool `scripts/renew-dev-certs.sh` supporting `--check-only`, `--force`, `--days`, `--threshold`, `--cert-dir`, `--san`.
- `CertificateManager` Swift service in `Sources/StudentAppBackend/Services/CertificateManager.swift`.
- Pre-flight check integration in `configureTLS` in `configure.swift`.
- Configuration flags in `AppConfig` (`autoRenewDevCerts`, `devCertRenewalThresholdDays`).
- PKCS#12 bundle (`localhost.p12`) generation for macOS Keychain and iOS simulator trust.
- Unit and integration tests in `StudentAppBackendTests.swift`.
- Documentation in `.env.example` and `README.md`.

### Out of Scope
- Production ACME / Let's Encrypt client implementation (production TLS is handled at edge reverse proxies or platform ingress).
- Modifying OS-level trust stores (trusting the certificate in Keychain or browser remains a user action).

## 4. Actors
- **Developer**: Runs local development server or CLI renewal script.
- **CI / Docker Runner**: Automatically generates development certificates during container or test setup.
- **Vapor Backend Application**: Inspects certificate health during startup pre-flight.
- **Client (iOS StudyApp / Web Browser)**: Communicates with backend over HTTPS.

## 5. Functional Requirements
- **FR-001**: The system MUST inspect the expiration date (`notAfter`) of an existing certificate file and calculate remaining validity days.
- **FR-002**: When a certificate is missing, expired, or expiring within `<threshold>` days (default: 30 days), the system MUST support regenerating a 2048-bit RSA private key and self-signed X.509 certificate.
- **FR-003**: The generated certificate MUST include Subject Alternative Names (SAN) containing at least `DNS:localhost`, `IP:127.0.0.1`, and `IP:::1` (where `IP:::1` represents OpenSSL's `IP:` prefix concatenated with the IPv6 loopback literal `::1`).
- **FR-004**: The system MUST support bundling the private key and certificate into a PKCS#12 file (`localhost.p12`) with an empty password.
- **FR-005**: The system MUST set POSIX permissions to `0600` (read/write for owner only) for the private key and `.p12` file, and `0644` for the public certificate.
- **FR-006**: The standalone script (`scripts/renew-dev-certs.sh`) MUST support:
  - `--check-only`: Returns exit code 0 if certificate is valid beyond threshold; returns exit code 1 if missing, expired, or expiring.
  - `--force`: Unconditionally regenerates new certificates.
  - `--days <N>`: Sets validity duration in days (default: 365).
  - `--threshold <N>`: Sets expiration warning/renewal threshold in days (default: 30).
  - `--cert-dir <DIR>`: Sets destination directory (default: `certs/`).
- **FR-007**: When `ENABLE_HTTPS=true` and `app.environment == .development`, `configureTLS` MUST run a certificate health pre-flight check. If `AUTO_RENEW_DEV_CERTS=true` (default in dev), it MUST automatically renew expiring or missing certificates.
- **FR-008**: Self-signed certificate generation or auto-renewal MUST be strictly disabled in `.production`.

## 6. Non-Functional Requirements
- **NFR-001 (Security)**: Private keys must never be world-readable. Auto-renewal must never execute in production.
- **NFR-002 (Portability)**: The CLI script must be POSIX-compliant and run without external dependencies beyond standard `openssl` on macOS (Darwin) and Linux (Ubuntu, Debian, Alpine, WSL, Docker).
- **NFR-003 (Idempotency)**: Running the script or pre-flight check on an already valid certificate must be a fast, safe no-op.
- **NFR-004 (Performance)**: Certificate validity check must take < 50ms during startup.

## 7. Business Rules
- **BR-001**: Production servers must never generate self-signed certificates at runtime.
- **BR-002**: Development certificates must remain valid for 365 days by default, with automatic renewal triggered when less than 30 days remain.
- **BR-003**: Default SAN list must cover localhost IPv4 and IPv6 loopback addresses.

## 8. Validation Rules
- **VAL-001**: `--days` and `--threshold` must be positive integers.
- **VAL-002**: Destination directory must be created if not already existing.

## 9. API Contract
This feature operates at the infrastructure/tooling layer. No REST or GraphQL endpoints are modified.

## 10. Database Requirements
No database tables, migrations, or queries required.

## 11. Security Requirements
- **SEC-001 (Input Validation)**:
  - `--days` must be an integer >= 1.
  - `--threshold` must be an integer >= 0.
  - `--san` must strictly match regex `^[A-Za-z0-9_.:,-]+$`.
- **SEC-002 (Path Traversal Protection)**:
  - `--cert-dir` and Swift `certDir` must disallow directory traversal (`..`) and null bytes (`\0`).
  - Sensitive system roots (`/`, `/etc`, `/dev`, `/sys`, `/proc`, `/bin`, `/usr`, `/sbin`) are explicitly forbidden.
- **SEC-003 (File Permission Atomicity)**:
  - Inode creation permissions are governed by `umask 0077`, ensuring private keys (`key.pem`) and PKCS#12 bundles (`localhost.p12`) are created with `0600` mode without any race condition window. Public cert is adjusted to `0644`.
- **SEC-004 (PKCS#12 Password Security)**:
  - Development `.p12` bundle uses empty password (`pass:`) intentionally for zero-friction macOS Keychain & iOS Simulator imports. It is strictly forbidden in `.production` and guarded by `0600` permissions.
- **SEC-005 (Subprocess Pipe Reliability)**:
  - Subprocess pipes for discarded output use `FileHandle.nullDevice` to eliminate OS buffer deadlock risks.

## 12. Concurrency Requirements
- File generation runs sequentially during server initialization or CLI execution before concurrent worker threads accept incoming TLS connections.

## 13. Error Handling
- If OpenSSL is missing from PATH, script exits with code 127 and diagnostic message.
- If certificate generation fails, previous certificate files are not corrupted.
- In production, attempting self-signed auto-renewal throws `Abort(.internalServerError, reason: "Self-signed certificate auto-renewal is forbidden in production")`.

## 14. Acceptance Criteria
- **AC-001**: Given no certificates in `certs/`, when `./scripts/renew-dev-certs.sh` is executed, valid `cert.pem`, `key.pem`, and `localhost.p12` are generated with modern SANs and correct permissions.
- **AC-002**: Given a certificate expiring within 30 days or already expired, when `./scripts/renew-dev-certs.sh` runs, new certificates with 365-day validity are generated.
- **AC-003**: Given a valid certificate with >30 days remaining, when `./scripts/renew-dev-certs.sh` runs without `--force`, it exits cleanly without re-generating files.
- **AC-004**: Given `./scripts/renew-dev-certs.sh --check-only`, it exits with 0 for valid certs and 1 for expiring/missing certs without writing files.
- **AC-005**: Given `app.environment == .production`, `CertificateManager` refuses to renew self-signed certificates and throws an error.
- **AC-006**: Given malicious or invalid inputs (`--san`, `--days`, `--threshold`, `--cert-dir`), the system fails fast with error status 1 and prevents injection.

## 15. Test Scenarios
### Unit Tests
- `testCertificateStatusMissing`: detects non-existent certificate file.
- `testCertificateStatusExpired`: detects expired certificate.
- `testCertificateStatusExpiringSoon`: detects certificate expiring within threshold.
- `testCertificateRenewalExecution`: creates valid certificate with SANs and correct permissions.
- `testCertificateRenewalIdempotency`: does not regenerate when certificate is healthy.
- `testProductionSafetyGuard`: rejects renewal when environment is production.
- `certificateCLISecurityValidation`: verifies script rejects invalid numeric values, directory traversal, sensitive system directories, and SAN injection attempts.
- `certificateManagerSecurityValidation`: verifies Swift service rejects directory traversal, system paths, and invalid SAN characters.

### Integration Tests
- Run `scripts/renew-dev-certs.sh --check-only` and `--force` in a temporary test directory.
- Verify server startup with `ENABLE_HTTPS=true` under `.development` automatically ensures valid certificates.

### Manual Security Testing Checklist (CHK-010)

| Test ID | Vulnerability Tested | Test Command | Expected Output & Code |
| :--- | :--- | :--- | :--- |
| **SEC-TEST-01** | Shell Injection via SANs | `./scripts/renew-dev-certs.sh --san "DNS:localhost; rm -rf /"` | `Error: --san contains invalid characters...` (Exit: 1) |
| **SEC-TEST-02** | Command Substitution via SANs | `./scripts/renew-dev-certs.sh --san 'DNS:localhost`id`'` | `Error: --san contains invalid characters...` (Exit: 1) |
| **SEC-TEST-03** | Non-numeric `--days` | `./scripts/renew-dev-certs.sh --days abc` | `Error: --days must be a positive integer` (Exit: 1) |
| **SEC-TEST-04** | Negative / Zero `--days` | `./scripts/renew-dev-certs.sh --days 0` | `Error: --days must be a positive integer` (Exit: 1) |
| **SEC-TEST-05** | Negative `--threshold` | `./scripts/renew-dev-certs.sh --threshold -5` | `Error: --threshold must be a non-negative integer` (Exit: 1) |
| **SEC-TEST-06** | Directory Traversal (`..`) | `./scripts/renew-dev-certs.sh --cert-dir "../sensitive"` | `Error: --cert-dir cannot contain directory traversal '..'` (Exit: 1) |
| **SEC-TEST-07** | Sensitive System Path Target | `./scripts/renew-dev-certs.sh --cert-dir "/etc"` | `Error: --cert-dir cannot target sensitive system directories` (Exit: 1) |
| **SEC-TEST-08** | Inode Permission Atomicity | `umask; ./scripts/renew-dev-certs.sh --force; stat -f "%Lp %N" certs/*` | Key/P12: `600`, Cert: `644` (Exit: 0) |
| **SEC-TEST-09** | Production Environment Block | Run app in `.production` with `CertificateManager.renewDevelopmentCertificates()` | Throws `Abort(.internalServerError)` |

## 16. Observability
- Server logs notice/warning on startup indicating certificate status, days remaining, and whether automatic renewal was executed.

## 17. Open Questions
None. All requirements clarified and approved.

## 18. Assumptions
- OpenSSL (v1.1.1+ or v3.0+) is available in standard developer and container environments.
