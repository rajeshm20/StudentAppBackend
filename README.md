# StudentAppBackend -- Run on WSL with Docker

## Prerequisites

-   Windows 11 with WSL2 (Ubuntu)
-   Docker installed and running
-   Git
-   Ports:
    -   MySQL: 3306 (or update as needed)
    -   App: use 8081 on host if 8080 is occupied by Jenkins

## 1. Clone the repository

``` bash
git clone https://github.com/rajeshm20/StudentAppBackend.git
cd StudentAppBackend
```

Verify the project contains:

``` bash
ls
```

Expected:

-   Dockerfile
-   Package.swift
-   Sources/

## 2. Build the Docker image (AMD64)

``` bash
docker buildx create --use --name mybuilder
docker buildx inspect --bootstrap
```

Build:

``` bash
docker buildx build \
  --platform linux/amd64 \
  -t studentappbackend:local \
  --load .
```

> This Dockerfile already builds Swift inside the container
> (`FROM swift:6.0-noble`), so **Swift does not need to be installed in
> WSL**.

## 3. Start MySQL

If using Docker Compose:

``` bash
docker compose up -d db
```

or start your MySQL container before the backend.

Verify:

``` bash
docker ps
```

## 4. Run the backend

If 8080 is already used (for example by Jenkins), map another host port:

``` bash
docker run -p 8081:8080 studentappbackend:local
```

Open:

http://localhost:8081

## 5. Common issues

### ARM64 image on AMD64

Error:

``` text
exec ./StudentAppBackend: exec format error
```

Cause: - Image built on Apple Silicon (ARM64).

Fix: - Rebuild in WSL using:

``` bash
docker buildx build \
  --platform linux/amd64 \
  -t studentappbackend:local \
  --load .
```

### Port already in use

Check:

``` bash
sudo ss -tulpn | grep :8080
```

Run on another host port:

``` bash
docker run -p 8081:8080 studentappbackend:local
```

### MySQL connection refused

Ensure MySQL container is running:

``` bash
docker ps
```

If using Docker Compose, start the full stack:

``` bash
docker compose up -d
```

## 6. Create a Git branch

``` bash
git checkout -b wsl_studentappbackend
git add .
git commit -m "Build and configure StudentAppBackend for WSL"
git push -u origin wsl_studentappbackend
```

> GitHub no longer accepts account passwords for Git operations. Use SSH
> or a Personal Access Token.

## 7. Publish a Docker image to GHCR

Tag:

``` bash
docker tag studentappbackend:local ghcr.io/rajeshm20/studentappbackend:wsl-v1
```

Login:

``` bash
docker login ghcr.io -u rajeshm20
```

Use a GitHub Personal Access Token (Classic) with:

-   read:packages
-   write:packages
-   repo (if repository is private)

Push:

``` bash
docker push ghcr.io/rajeshm20/studentappbackend:wsl-v1
```

## Useful commands

``` bash
docker images
docker ps
docker logs <container>
docker image inspect studentappbackend:local
docker buildx ls
docker network ls
```

--------------------------------------------------------------------------------

# StudentAppBackend

Vapor-based Swift backend that exposes student authentication APIs over REST and additional student APIs over GraphQL.

## Overview

- Framework: Vapor 4
- Language: Swift 6
- Database: MySQL
- API styles: REST and GraphQL
- Container registry: GitHub Container Registry

## Features

- Student signup and login over REST
- GraphQL endpoint for student queries and mutations
- JWT-based authentication
- Docker-based local development
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

## Requirements

- macOS 13 or later
- Swift 6 toolchain / Xcode compatible with the package
- MySQL 8 if running outside Docker
- Docker and Docker Compose for container-based setup

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

## Docker

### Published Image

The backend container is published to GitHub Container Registry through the workflow at `.github/workflows/docker-publish.yml`.

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

### Complete Packaged Setup

The published image contains only the backend application. To run the backend together with MySQL, use [`docker-compose.package.yml`](docker-compose.package.yml).

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

Note: if you add schema fields such as `updateStudent`, document them here only after they are implemented in the current codebase.

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

To run the backend behind Caddy with TLS termination, use [`docker-compose.caddy.yml`](docker-compose.caddy.yml).

```bash
docker compose -f docker-compose.caddy.yml up -d
```

This keeps the backend container on HTTP and lets Caddy manage HTTPS on port `443`.

For local Caddy testing, use:

```text
https://localhost
```

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

## Deployment Notes

- In Docker or production environments, keep the app container on HTTP.
- Terminate TLS in Caddy, Nginx, or another reverse proxy.
- Do not package local self-signed certificates into production images.

## References

- [Vapor Website](https://vapor.codes)
- [Vapor Documentation](https://docs.vapor.codes)
- [Vapor GitHub](https://github.com/vapor)
- [Vapor Community](https://github.com/vapor-community)
