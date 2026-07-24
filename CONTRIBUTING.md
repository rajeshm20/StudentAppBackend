# Contributing to StudentAppBackend

Thanks for your interest in contributing to StudentAppBackend — a Vapor-based Swift backend exposing student authentication and student data APIs over REST and GraphQL. This document covers how to set up the project, the expected workflow, and coding conventions.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Project Structure](#project-structure)
- [Coding Guidelines](#coding-guidelines)
- [Testing](#testing)
- [Docker Workflow](#docker-workflow)
- [Commit Messages](#commit-messages)
- [Pull Requests](#pull-requests)
- [Reporting Issues](#reporting-issues)
- [Security Issues](#security-issues)

## Code of Conduct

Be respectful and constructive. Assume good intent, keep discussion focused on the code and the problem at hand, and avoid personal remarks in reviews or issues.

## Getting Started

### Requirements

- macOS 13 or later
- Swift 6 toolchain / Xcode compatible with the package
- MySQL 8 (if running outside Docker)
- Docker and Docker Compose (for container-based setup)

### Fork and Clone

```bash
git clone https://github.com/<your-username>/StudentAppBackend.git
cd StudentAppBackend
git remote add upstream https://github.com/rajeshm20/StudentAppBackend.git
```

### Build and Run

```bash
swift build
swift run
```

### Run with Docker

For local source-based development:

```bash
docker compose up -d
```

For the packaged backend + MySQL setup:

```bash
docker compose -f docker-compose.package.yml up -d
```

If MySQL was previously started with older credentials, recreate the volume:

```bash
docker compose -f docker-compose.package.yml down -v
docker compose -f docker-compose.package.yml up -d
```

## Development Workflow

1. Create a branch off `main` for your change:
   ```bash
   git checkout -b feature/short-description
   ```
2. Make your changes, following the [Coding Guidelines](#coding-guidelines) below.
3. Add or update tests in `Tests/StudentAppBackendTests` for any behavior change.
4. Run the full test suite locally before opening a PR.
5. Update the `README.md` if you change setup steps, endpoints, or environment variables.
6. Push your branch and open a pull request against `main`.

Please keep pull requests focused on a single change — smaller PRs are easier to review and merge.

## Project Structure

- `Sources/StudentAppBackend` — application source (routes, controllers, GraphQL, services, models, migrations, middleware)
- `Tests/StudentAppBackendTests` — test suite
- `docker-compose.yml` — local source-based development
- `docker-compose.package.yml` — packaged backend + MySQL
- `docker-compose.caddy.yml` — backend behind Caddy with HTTPS termination
- `docs/diagrams` — PlantUML source and rendered diagrams for server runtime and code architecture
- `.github/workflows` — CI, including the `docker-publish.yml` workflow that publishes images to GHCR

If you're changing how components interact, please update the relevant `.puml` diagram in `docs/diagrams` alongside your code change.

## Coding Guidelines

- Follow standard Swift API design guidelines and existing formatting in the codebase.
- Keep controllers thin — push business logic into services, and database access into models/migrations.
- New REST routes and GraphQL operations should have a corresponding entry in `README.md` under **API Endpoints**, including a working `curl` example.
- Avoid introducing new third-party dependencies unless necessary; discuss significant dependency additions in an issue first.
- Do not hardcode secrets, API keys, or credentials anywhere in source, `Dockerfile`, or committed `.env` files. Configuration should be read from environment variables.

## Testing

Run the test suite with:

```bash
swift test
```

- New endpoints (REST or GraphQL) should include at least one success-path test and one failure/validation-path test.
- Tests should not depend on external services being reachable; use the project's existing patterns for a test database/mocking where available.

## Docker Workflow

- The backend image is published to GHCR via `.github/workflows/docker-publish.yml` on pushes to `main` and on version tags (e.g. `v1.0.0`).
- Do not modify the publish workflow to bake secrets or API keys into the image. Runtime configuration (database credentials, JWT secrets, third-party API keys) must be passed as environment variables at container run time, not embedded in the `Dockerfile`.
- If you change the `Dockerfile`, verify both `docker-compose.yml` (source build) and `docker-compose.package.yml` (published image) still work.
- Keep the app container on plain HTTP; TLS termination is handled by Caddy (see `docker-compose.caddy.yml`). Don't package local self-signed certificates into images intended for production use.

## Commit Messages

Use clear, descriptive commit messages. Prefixing with a type is encouraged but not required:

```
feat: add updateStudent GraphQL mutation
fix: correct UUID parsing in student signup payload
docs: update README with new environment variables
test: add coverage for login rate limiting
```

## Pull Requests

Before opening a PR, please confirm:

- [ ] The project builds (`swift build`) with no warnings you introduced
- [ ] `swift test` passes locally
- [ ] New/changed endpoints are documented in `README.md`
- [ ] No secrets, credentials, or API keys are included in the diff
- [ ] Relevant architecture diagrams are updated if the change affects them

In the PR description, briefly explain **what** changed and **why**, and link any related issue.

## Reporting Issues

When filing a bug report, please include:

- Steps to reproduce
- Expected vs. actual behavior
- Whether you're running via Docker, source build, or packaged setup
- Relevant logs or error output (with any secrets redacted)

## Security Issues

Please do not open a public issue for security vulnerabilities. Instead, contact the maintainer directly to report the issue responsibly.
