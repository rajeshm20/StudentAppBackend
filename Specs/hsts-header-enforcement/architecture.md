# Architecture: HSTS Header Enforcement & Middleware Pipeline

## 1. Overview
This document outlines the architectural flow, security boundaries, and middleware pipeline design for HTTP Strict Transport Security (HSTS) enforcement in `StudentAppBackend`.

## 2. Request Flow & Security Boundary

```
+-------------------------------------------------------------------------------+
| Client (Browser / iOS App)                                                    |
+-------------------------------------------------------------------------------+
         |
         | (HTTPS: Port 443)
         v
+-------------------------------------------------------------------------------+
| Edge Reverse Proxy (Caddy)                                                    |
| - Terminates TLS 1.2 / 1.3 with PFS & AEAD Ciphers                            |
| - Injects Edge HSTS Header (defense-in-depth)                                 |
| - Sets Header: X-Forwarded-Proto https                                        |
| - Sets Header: X-Forwarded-Host {host}                                        |
+-------------------------------------------------------------------------------+
         |
         | (HTTP: app:8080)
         v
+-------------------------------------------------------------------------------+
| Vapor Backend Application Server                                              |
|                                                                               |
|  [SecurityHeadersMiddleware] (Position: .beginning)                           |
|    |                                                                          |
|    +---> Checks isSecureConnection(request):                                  |
|    |       - request.url.scheme == "https"                                    |
|    |       - X-Forwarded-Proto == "https"                                     |
|    |                                                                          |
|    v                                                                          |
|  [ErrorMiddleware] (Vapor Default)                                            |
|    |                                                                          |
|    v                                                                          |
|  [CORSMiddleware]                                                             |
|    |                                                                          |
|    v                                                                          |
|  [RateLimiterMiddleware]                                                      |
|    |                                                                          |
|    v                                                                          |
|  [Route Handler / Controllers / Auth]                                         |
|    |                                                                          |
|    +---> Returns 200 OK or Throws Abort (400, 401, 403, 404, 429)             |
|                                                                               |
|  Response Unwinding:                                                          |
|  1. ErrorMiddleware catches any thrown Abort and builds error Response        |
|  2. SecurityHeadersMiddleware applies:                                        |
|       - Strict-Transport-Security (if isSecureConnection == true)             |
|       - X-Content-Type-Options: nosniff                                       |
|       - X-Frame-Options: DENY                                                 |
|       - Referrer-Policy: strict-origin-when-cross-origin                      |
|       - Permissions-Policy                                                    |
|       - Content-Security-Policy                                               |
|  3. Final Response with full headers returned to Client                       |
+-------------------------------------------------------------------------------+
```

## 3. RFC 6797 §7.2 Compliance & Cache Separation

RFC 6797 Section 7.2 states:
> An HTTP host MUST NOT include the STS header field in HTTP responses conveyed over non-secure transport.

When requests are sent directly to Vapor or via plain HTTP without an `X-Forwarded-Proto: https` or RFC 7239 `Forwarded: proto=https` header:
- `isSecureConnection(request, environment: env)` evaluates to `false`.
- `SecurityHeadersMiddleware` explicitly strips or avoids attaching `Strict-Transport-Security`.
- Baseline security headers (`X-Content-Type-Options`, `X-Frame-Options`, etc.) are retained.
- When proxy headers are trusted, `Vary: X-Forwarded-Proto` is added to responses so downstream caches/CDNs do not serve plain HTTP cached responses over HTTPS or vice-versa (RFC 9111).

## 4. Configuration Matrix

| Environment Variable | Default Value | Description |
| :--- | :--- | :--- |
| `HSTS_ENABLED` | `false` (dev/test)<br>`true` (prod) | Enables or disables HSTS header emission. Gated off in dev/test by default. |
| `HSTS_MAX_AGE` | `2592000` | Max-age duration in seconds (30 days safe rollout default) |
| `HSTS_INCLUDE_SUBDOMAINS` | `false` | Includes `includeSubDomains` directive (requires explicit opt-in) |
| `HSTS_PRELOAD` | `false` | Includes `preload` directive (requires explicit opt-in + validation) |
| `TRUST_PROXY_HEADERS` | `true` | Evaluates forwarded headers from reverse proxies. Set `false` if exposed directly. |

## 5. Emergency Rollback Architecture
If an operational emergency occurs (e.g. certificate expiration, temporary HTTP fallback, or broken subdomain):
1. Operator sets `HSTS_MAX_AGE=0` in environment.
2. `AppConfig.hstsHeaderValue` renders `Strict-Transport-Security: max-age=0`.
3. Browsers receiving `max-age=0` instantly evict the HSTS policy for the domain.
