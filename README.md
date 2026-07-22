# StudentAppBackend — Linux / macOS Setup Guide

Vapor-based Swift backend that exposes student authentication APIs over REST and additional student APIs over GraphQL. This guide covers **native local development** on Linux and macOS, with optional Docker-based workflows.

---

## Overview

- **Framework:** Vapor 4
- **Language:** Swift 6
- **Database:** MySQL
- **API styles:** REST and GraphQL
- **Container registry:** GitHub Container Registry (GHCR)

## Features

- Student signup, login, and logout over REST
- GraphQL endpoint for student queries and mutations
- JWT-based authentication with token revocation on logout
- Centralized validation across REST and GraphQL
- Docker-based local development (optional)
- Optional HTTPS support for native local runs
- Optional reverse-proxy TLS termination with Caddy

## Server Diagram

[![Server Runtime Diagram](docs/diagrams/server-runtime.svg)](docs/diagrams/server-runtime.puml)

PlantUML source: [server-runtime.puml](docs/diagrams/server-runtime.puml)

This diagram shows the runtime flow between clients, the Vapor server, REST routes, GraphQL routes, authentication logic, and MySQL.

## Project Structure

- [`Sources/StudentAppBackend`](Sources/StudentAppBackend): application source
- [`Tests/StudentAppBackendTests`](Tests/StudentAppBackendTests): test suite
- [`docker-compose.yml`](docker-compose.yml): local source-based development
- [`docker-compose.package.yml`](docker-compose.package.yml): packaged backend + MySQL
- [`docker-compose.caddy.yml`](docker-compose.caddy.yml): backend behind Caddy with HTTPS termination

## Code Architecture

[![Code Architecture Diagram](docs/diagrams/code-architecture.svg)](docs/diagrams/code-architecture.puml)

PlantUML source: [code-architecture.puml](docs/diagrams/code-architecture.puml)

This diagram shows how `configure.swift`, routes, controllers, GraphQL, services, models, migrations, middleware, and tests fit together in the codebase.

---

## Requirements

- macOS 13 or later (or a modern Linux distribution)
- Swift 6 toolchain / Xcode compatible with the package
- MySQL 8 if running outside Docker
- Docker and Docker Compose for container-based setup (optional)

---

## Local Development

### Build

```bash
swift build
```

### Run

```bash
swift run
```

### Test

```bash
swift test
```

Current tests cover the REST auth flow, logout authorization behavior, logout token reuse rejection, GraphQL signup, and validation edge cases.

---

## Docker (Optional)

### Published Image

The backend container is published to GitHub Container Registry through the consolidated CI/CD workflow at `.github/workflows/swift.yml`.

- Default image: `ghcr.io/rajeshm20/studentappbackend:latest`
- Additional tags: `main`, release tags such as `v1.0.0`, and commit SHA tags

To publish from CI:

```bash
git push origin main
```

To publish a versioned image:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The Docker publish job runs only after the test job passes.

### Complete Packaged Setup

The published image contains only the backend application. To run the backend together with MySQL, use [`docker-compose.package.yml`](docker-compose.package.yml):

```bash
docker compose -f docker-compose.package.yml up -d
```

This package starts:

- `ghcr.io/rajeshm20/studentappbackend:latest`
- `mysql:8`

Default database-related values:

- `DATABASE_USER=root`
- `DATABASE_PASSWORD=newpassword`
- `MYSQL_ROOT_PASSWORD=newpassword`
- `MYSQL_ROOT_HOST=%`

For local development from source, use [`docker-compose.yml`](docker-compose.yml). It provides the same runtime shape but builds the backend image from this repository.

If MySQL was previously started with older credentials or host permissions, recreate the volume once:

```bash
docker compose -f docker-compose.package.yml down -v
docker compose -f docker-compose.package.yml up -d
```

---

## API Endpoints

### REST

Base URL for the packaged Docker setup:

```text
http://localhost:8080
```

#### Signup

```bash
curl -X POST http://localhost:8080/auth/signup \
  -H "Content-Type: application/json" \
  -d '{
    "name": "SasvathRN",
    "email": "sasvathrn@rnss.com",
    "password": "password123"
  }'
```

#### Login

```bash
curl -X POST http://localhost:8080/auth/login \
  -H "Content-Type: application/json" \
  -d '{
    "email": "rajesh@example.com",
    "password": "password123"
  }'
```

The login response includes a JWT token that you pass to protected flows such as logout.

#### Logout

```bash
curl -X POST http://localhost:8080/auth/logout \
  -H "Authorization: Bearer YOUR_JWT_TOKEN"
```

Expected success response:

```json
{
  "message": "Logout successful"
}
```

Logout behavior in the current implementation:

- Requires a bearer token in the `Authorization` header
- Verifies the JWT before processing the request
- Stores the token `jti` in the revoked-token table
- Rejects repeated logout attempts with the same token

#### Example Auth Flow with Logout

1. Sign up a user.
2. Log in and capture the returned token.
3. Call logout with that token.

Example logout after login:

```bash
curl -X POST http://localhost:8080/auth/logout \
  -H "Authorization: Bearer eyJhbGciOi..."
```

### GraphQL

GraphQL is exposed at:

```text
POST /graphql
```

GraphiQL is available at:

```text
GET /graphiql
```

Current GraphQL operations:

- `students`: fetch all students
- `student(id: UUID!)`: fetch a single student
- `signup(input: StudentGraphQLCreateInput!)`: create a student
- `login(input: StudentGraphQLLoginInput!)`: authenticate and return a JWT
- `updateStudent(input: StudentGraphQLUpdateInput!)`: update `dob`, `name`, and `phoneNumber`

#### Signup Mutation

```bash
curl -X POST http://localhost:8080/graphql \
  -H "Content-Type: application/json" \
  -d '{
    "query": "mutation Signup($input: StudentGraphQLCreateInput!) { signup(input: $input) { id name email } }",
    "variables": {
      "input": {
        "name": "Graph User",
        "email": "graphql@example.com",
        "password": "password123"
      }
    }
  }'
```

#### Login Mutation

```bash
curl -X POST http://localhost:8080/graphql \
  -H "Content-Type: application/json" \
  -d '{
    "query": "mutation Login($input: StudentGraphQLLoginInput!) { login(input: $input) { token user { id name email } } }",
    "variables": {
      "input": {
        "email": "graphql@example.com",
        "password": "password123"
      }
    }
  }'
```

#### Update Student Mutation

```bash
curl -X POST http://localhost:8080/graphql \
  -H "Content-Type: application/json" \
  -d '{
    "query": "mutation UpdateStudent($input: StudentGraphQLUpdateInput!) { updateStudent(input: $input) { id name phoneNumber dob } }",
    "variables": {
      "input": {
        "id": "PUT-STUDENT-UUID-HERE",
        "name": "Updated Name",
        "phoneNumber": "+1 234 567 8900"
      }
    }
  }'
```

#### Students Query

```bash
curl -X POST http://localhost:8080/graphql \
  -H "Content-Type: application/json" \
  -d '{
    "query": "{ students { id name email phoneNumber dob } }"
  }'
```

Minimal students query:

```bash
curl -X POST http://localhost:8080/graphql \
  -H "Content-Type: application/json" \
  -d '{
    "query": "{ students { id name email } }"
  }'
```

---

## Validation Hardening

The current backend applies validation in multiple layers so invalid data is rejected before it can silently drift into persistence.

### Where Validation Runs

- REST signup uses Vapor validation plus shared `ValidationUtilities.swift` checks
- GraphQL signup reuses the same create-request validation rules
- GraphQL `updateStudent` validates `dob`, `name`, and `phoneNumber`
- MySQL schema constraints backstop key field lengths at the database level

### Current Validation Rules

#### Name

- Required for signup
- Must not be empty or whitespace-only
- Maximum length: 100 characters

#### Email

- Required for signup
- Must match email format rules
- Maximum length: 254 characters
- Still enforced as unique at the database level

#### Password

- Required for signup
- Minimum length: 8 characters
- Must contain at least one letter and one number

#### Date of Birth

- Optional
- Must not be in the future
- Must represent a plausible age between 5 and 120 years

#### Phone Number

- Optional
- Must be 10 to 20 characters
- May contain only digits, `+`, `-`, and spaces

### Database-Level Backstop

The `students` schema adds `CHECK` constraints for:

- `name` length up to 100 characters
- `email` length up to 254 characters
- `phoneNumber` length between 10 and 20 characters when present

This means malformed or oversized values are not only blocked at the API layer, but also guarded at the database layer.

### Example Invalid Signup Request

```bash
curl -X POST http://localhost:8080/auth/signup \
  -H "Content-Type: application/json" \
  -d '{
    "name": "",
    "email": "not-an-email",
    "password": "short"
  }'
```

Expected behavior:

- HTTP `400 Bad Request`
- Validation failure reason returned by the API
- No student row created

### Validation Test Coverage

The current test suite includes cases for:

- empty and oversized names
- malformed and oversized emails
- weak passwords
- future and implausible dates of birth
- malformed, too-short, and too-long phone numbers
- valid payloads with optional fields present or absent

---

## HTTPS

### Native Local HTTPS

If running the Vapor app directly and you want local HTTPS, generate a self-signed certificate with `CN=localhost`.

1. Generate the certificate and key.

```bash
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout key.pem -out cert.pem -days 365 \
  -subj "/CN=localhost"
```

2. Export a `.p12` bundle if needed.

```bash
openssl pkcs12 -export -out localhost.p12 \
  -inkey key.pem -in cert.pem \
  -name "Vapor Localhost Cert"
```

3. Import `cert.pem` into macOS Keychain and set it to trust for local use.
4. Restart the Vapor application so it reloads the certificates.
5. Test the endpoint again.

```bash
curl https://localhost:8080/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"rajesh@example.com","password":"password123"}'
```

### HTTPS with Caddy

To run the backend behind Caddy with TLS termination, use [`docker-compose.caddy.yml`](docker-compose.caddy.yml):

```bash
docker compose -f docker-compose.caddy.yml up -d
```

This keeps the backend container on HTTP and lets Caddy manage HTTPS on port `443`.

For local Caddy testing, use:

```text
https://localhost
```

---

## MySQL Setup on macOS

If you are not using Docker, install and configure MySQL locally.

### Install

```bash
brew update
brew install mysql
```

### Start

Start MySQL as a background service:

```bash
brew services start mysql
```

Or start it manually when needed:

```bash
mysql.server start
```

### Secure the Installation

```bash
mysql_secure_installation
```

Recommended actions during setup:

- Set a root password
- Remove anonymous users
- Disallow remote root login unless explicitly required
- Remove the test database
- Reload privilege tables

### Connect

```bash
mysql -u root -p -h 127.0.0.1 -P 3306
```

---

## Deployment Notes

- In Docker or production environments, keep the app container on HTTP.
- Terminate TLS in Caddy, Nginx, or another reverse proxy.
- Do not package local self-signed certificates into production images.

---

## References

- [Vapor Website](https://vapor.codes)
- [Vapor Documentation](https://docs.vapor.codes)
- [Vapor GitHub](https://github.com/vapor)
- [Vapor Community](https://github.com/vapor-community)
