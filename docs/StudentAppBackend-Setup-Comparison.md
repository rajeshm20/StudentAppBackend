# StudentAppBackend — Setup Guide Comparison

Side-by-side comparison of the **WSL + Docker** setup vs the **Linux / macOS (native)** setup.

## Server Diagram

[![Server Runtime Diagram](diagrams/server-runtime.svg)](diagrams/server-runtime.puml)

PlantUML source: [server-runtime.puml](diagrams/server-runtime.puml)

This diagram shows the runtime flow between clients, the Vapor server, REST routes, GraphQL routes, authentication logic, and MySQL.

## Project Structure

- [`Sources/StudentAppBackend`](Sources/StudentAppBackend): application source
- [`Tests/StudentAppBackendTests`](Tests/StudentAppBackendTests): test suite
- [`docker-compose.yml`](docker-compose.yml): local source-based development
- [`docker-compose.package.yml`](docker-compose.package.yml): packaged backend + MySQL
- [`docker-compose.caddy.yml`](docker-compose.caddy.yml): backend behind Caddy with HTTPS termination

## Code Architecture

[![Code Architecture Diagram](diagrams/code-architecture.svg)](diagrams/code-architecture.puml)

PlantUML source: [code-architecture.puml](diagrams/code-architecture.puml)

This diagram shows how `configure.swift`, routes, controllers, GraphQL, services, models, migrations, middleware, and tests fit together in the codebase.

| | **WSL + Docker Setup Guide** | **Linux / macOS Setup Guide** |
|---|---|---|
| **Target environment** | Windows 11 with WSL2 (Ubuntu), everything runs via Docker | Native Linux or macOS, with Docker optional |
| **Prerequisites** | Windows 11 + WSL2 (Ubuntu)<br>Docker installed and running<br>Git<br>Ports: MySQL `3306`, App `8081` if `8080` is taken | macOS 13+ or modern Linux<br>Swift 6 toolchain / Xcode<br>MySQL 8 (if not using Docker)<br>Docker + Compose (optional) |
| **Clone repo** | `git clone https://github.com/rajeshm20/StudentAppBackend.git`<br>`cd StudentAppBackend`<br>`ls` (expect `Dockerfile`, `Package.swift`, `Sources/`) | Same clone step, but typically followed by native build rather than Docker build |
| **Build the app** | `docker buildx create --use --name mybuilder`<br>`docker buildx inspect --bootstrap`<br>`docker buildx build --platform linux/amd64 -t studentappbackend:local --load .` | `swift build` |
| **Run the app** | `docker run -p 8081:8080 studentappbackend:local` | `swift run` |
| **Run tests** | Handled inside CI container (`swift test -v`); current coverage includes signup, login, logout, and logout token-reuse cases | `swift test`; current coverage includes signup, login, logout, and logout token-reuse cases |
| **Database setup** | `docker compose up -d db` (MySQL runs in a container)<br>Verify: `docker ps` | Docker Compose **or** native Homebrew MySQL:<br>`brew install mysql`<br>`brew services start mysql`<br>`mysql_secure_installation` |
| **Common issues** | **ARM64 image on AMD64** → `exec format error`, fix with `--platform linux/amd64` rebuild<br>**Port in use** → `sudo ss -tulpn \| grep :8080`, remap with `-p 8081:8080`<br>**MySQL refused** → check `docker ps`, or `docker compose up -d` | Not covered — native builds don't hit the ARM64/AMD64 container mismatch; port conflicts are OS-level (`lsof -i :8080` on macOS/Linux) |
| **Git branch workflow** | `git checkout -b wsl_studentappbackend`<br>`git add .`<br>`git commit -m "..."`<br>`git push -u origin wsl_studentappbackend` | Not specific to platform — standard feature-branch workflow applies |
| **Publish to GHCR (manual)** | `docker tag studentappbackend:local ghcr.io/rajeshm20/studentappbackend:wsl-v1`<br>`docker login ghcr.io -u rajeshm20`<br>`docker push ghcr.io/rajeshm20/studentappbackend:wsl-v1` | Same manual tag/login/push steps apply if building locally on macOS/Linux |
| **Publish via CI** | `git push origin main` (latest)<br>`git tag v1.0.0 && git push origin v1.0.0` (versioned) | Identical — CI publishing is platform-agnostic |
| **Packaged setup (app + DB)** | `docker compose -f docker-compose.package.yml up -d` | Same command, same defaults (`DATABASE_USER=root`, `DATABASE_PASSWORD=newpassword`, etc.) |
| **HTTPS (native, no proxy)** | Not covered — WSL guide assumes Docker/HTTP only | `openssl req -x509 -newkey rsa:2048 ...` to generate self-signed cert<br>Optional `.p12` export<br>Import into macOS Keychain |
| **HTTPS via Caddy** | `docker compose -f docker-compose.caddy.yml up -d` | Same command — identical across both guides |
| **API endpoints (REST/GraphQL)** | Same base URL (`http://localhost:8080`), same REST auth routes `/auth/signup`, `/auth/login`, `/auth/logout`, plus `/graphql` and `/graphiql` | Identical API surface across platforms; logout requires `Authorization: Bearer <jwt>` and revokes the token by JWT ID |
| **Deployment notes** | Keep app container on HTTP; terminate TLS at Caddy/Nginx; never ship self-signed certs in prod images | Same guidance |
| **Unique to this guide** | ARM64/AMD64 troubleshooting, WSL-specific branch naming convention, buildx multi-platform build steps | Native `swift build/run/test` workflow, macOS Keychain cert trust steps, Homebrew MySQL install/secure/connect steps |

---

## Quick Takeaway

- **Choose WSL + Docker** if you're on Windows and want a fully containerized workflow with no native Swift toolchain installed.
- **Choose Linux/macOS native** if you're developing directly with Xcode/Swift tooling and want faster iteration (`swift run` / `swift test`) without rebuilding Docker images on every change.
- Both guides converge on the **same auth/API surface, including logout token revocation, same GHCR publishing workflow, and same Caddy/HTTPS reverse-proxy setup** — the only real divergence is *how the binary gets built and run locally*.
