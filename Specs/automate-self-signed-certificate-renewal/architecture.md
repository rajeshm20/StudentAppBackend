# Architecture: Automated Self-Signed Certificate Renewal for Development

## 1. Overview
This document outlines the architectural lifecycle, operational boundaries, and security design for automated self-signed certificate generation and renewal in `StudentAppBackend`.

## 2. Component Diagram & Lifecycle Flow

```
+-------------------------------------------------------------------------------+
| Developer / CI / Docker Runner                                                |
+-------------------------------------------------------------------------------+
         |
         | (1) Manual / Pre-build CLI invocation: ./scripts/renew-dev-certs.sh
         v
+-------------------------------------------------------------------------------+
| scripts/renew-dev-certs.sh (Portable Shell CLI)                               |
| - Inspects certs/cert.pem using openssl x509 -checkend <threshold>           |
| - If valid (> threshold days): exits 0 without modifying files               |
| - If expired / missing / --force:                                             |
|   1. Generates 2048-bit RSA key (key.pem, chmod 600)                          |
|   2. Generates X.509 cert with SANs (cert.pem, chmod 644)                     |
|   3. Exports PKCS#12 bundle (localhost.p12, chmod 600)                        |
+-------------------------------------------------------------------------------+
         |
         | Writes files to certs/ directory
         v
+-------------------------------------------------------------------------------+
| certs/ directory                                                              |
| - cert.pem       (Public X.509 Certificate with SAN extensions)               |
| - key.pem        (Private Key - 0600 permissions)                             |
| - localhost.p12  (PKCS#12 bundle for Keychain / Simulator trust)              |
+-------------------------------------------------------------------------------+
         ^
         |
         | (2) Runtime Pre-flight check in configureTLS
+-------------------------------------------------------------------------------+
| Vapor Backend Application Server                                              |
|                                                                               |
|  [configureTLS]                                                               |
|    |                                                                          |
|    +---> [AppConfig.autoRenewDevCerts]                                        |
|            |                                                                  |
|            +---> Check: app.environment == .development                       |
|            |                                                                  |
|            +---> [CertificateManager.ensureDevelopmentCertificates]           |
|            |       - Checks cert status via OpenSSL / File inspection         |
|            |       - If missing/expiring: auto-renews via CLI execution       |
|            |       - If .production: STRICT NO-OP / ABORT                     |
|            |                                                                  |
|            v                                                                  |
|  [SwiftNIO SSL TLSConfiguration]                                              |
|    - Loads certs/cert.pem & certs/key.pem                                     |
|    - Binds HTTPS listener with TLS 1.2+ & AEAD ciphers                        |
+-------------------------------------------------------------------------------+
```

## 3. Security Boundary & Production Guardrails

| Attribute | Development (`.development`) | Production (`.production`) |
| :--- | :--- | :--- |
| **Certificate Authority** | Self-Signed (`CN=localhost`) | Trusted Public CA / Let's Encrypt / ACME |
| **Auto-Renewal Source** | Local `scripts/renew-dev-certs.sh` | Reverse proxy (Caddy/Nginx) or Platform Ingress |
| **Key Permissions** | `0600` (Owner read/write only) | `0600` (Mounted via Kubernetes / Docker Secret) |
| **Runtime Generation** | Allowed when `AUTO_RENEW_DEV_CERTS=true` | **Strictly Forbidden** (Causes startup failure) |
| **Pre-flight Behavior** | Auto-generates or warns if expired | Fail-fast validation in `validateProductionSecrets` |

## 4. Subject Alternative Names (SAN) Architecture
Modern TLS clients (macOS Safari, Google Chrome 58+, Mozilla Firefox, iOS URLSession) deprecate checking `commonName` alone and require the `subjectAltName` extension.

Generated certificates mandate:
```ini
subjectAltName = DNS:localhost, IP:127.0.0.1, IP:::1
```
This guarantees that local connections to `https://localhost:8080`, `https://127.0.0.1:8080`, and `https://[::1]:8080` all pass TLS hostname verification.

## 5. Script & Command Interface
The CLI script exposes a POSIX-compliant interface:
- `./scripts/renew-dev-certs.sh --check-only` (exit 0 if valid, 1 if renewal needed)
- `./scripts/renew-dev-certs.sh --force` (immediate regeneration)
- `./scripts/renew-dev-certs.sh --days 365 --threshold 30` (custom validity and renewal windows)
- `./scripts/renew-dev-certs.sh --cert-dir <PATH>` (sandbox directory testing)

## 6. Security Hardening & Vulnerability Mitigations

| Vulnerability Vector | Mitigation Mechanism | Implementation Detail |
| :--- | :--- | :--- |
| **Shell Injection via SANs** | Whitelist validation & explicit quoting | Both script and Swift validate SANs against `^[A-Za-z0-9_.:,-]+$`. Quoted expansion in openssl calls. |
| **Input Validation** | Strict numeric bounds checking | `--days` must be positive integer (`>= 1`); `--threshold` must be non-negative integer (`>= 0`). |
| **Path Traversal** | Traversal & system path blacklisting | Rejects `..` sequences, null bytes, and sensitive system root paths (`/`, `/etc`, `/dev`, `/bin`, `/usr`, `/proc`, `/sys`). |
| **Key Exposure Race Condition** | Inode creation `umask 0077` | Script applies `umask 0077` before file creation, guaranteeing private keys and PKCS#12 bundles are created with `0600` permissions. |
| **PKCS#12 Password Security** | Local development restriction & file isolation | Empty password (`pass:`) intentionally used for seamless macOS Keychain & iOS Simulator trust store import without prompts. Protected by `0600` permissions and forbidden in production. |
| **Subprocess Pipe Deadlocks** | `FileHandle.nullDevice` non-blocking pipes | Process stderr/stdout discarded directly to null device when unneeded, avoiding 64KB OS pipe buffer exhaustion deadlocks. |

