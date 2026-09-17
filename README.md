# Go Microservices Generator

A Bash-based generator for creating a Go microservices monorepo with a shared workflow.

## Quick Start

Initialize the repository and create the default authentication service:

```bash
make init:module github.com/owner/repo
```

Create another service:

```bash
make create:service payment-service PORT=8082
```

Copy the environment file, configure it, and run a service:

```bash
cp services/auth-service/.env.example services/auth-service/.env
make run:service auth-service
```

## Make Commands

Service-specific commands use the service name as a positional argument:

```bash
make run:service SERVICE_NAME
make build:service SERVICE_NAME
make test:service SERVICE_NAME
make tidy:service SERVICE_NAME
make clean:service SERVICE_NAME
make delete:service SERVICE_NAME
```

Create services with an optional port:

```bash
make create:service SERVICE_NAME PORT=8082
```

Run commands for every service:

```bash
make build-all
make test-all
make tidy-all
make fmt
make vet
make check
```

Repository management:

```bash
make list
make workspace
make doctor
```

Run `make help` for the complete command list.

## Generated Services

Each service is created under `services/<service-name>` and includes:

- A Go module
- HTTP API entrypoint
- Chi router
- PostgreSQL database integration with GORM
- JWT authentication middleware
- Service-level Makefile
- Dockerfile
- Example environment configuration

The default `auth-service` additionally includes users, roles, permissions, login, token generation, migrations, and admin seeding.

## Requirements

- Bash
- GNU Make
- Go

Docker is optional and is only needed for container workflows.
