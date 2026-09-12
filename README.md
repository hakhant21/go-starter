# Go Starter

`skeleton.sh` generates a complete Gin + GORM REST API project with JWT
authentication, refresh tokens, email verification, password reset, RBAC,
Redis caching, Prometheus metrics, tests, Docker, and GitHub Actions CI.

## Generate a project

Run the generator from this directory:

```sh
chmod +x skeleton.sh
./skeleton.sh
```

To download and run the generator with `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/hakhant21/go-starter/main/skeleton.sh | bash

```

Enter a project name when prompted. If no name is provided, the generated
directory is `starter/`. The script recreates the selected directory from
scratch. The script is not saved in either directory after generation.

## Run the generated project

Change into the generated directory, then configure and install dependencies:

```sh
cd starter # or the project name you entered
cp .env.example .env
go mod tidy
```

Start the API and its PostgreSQL, Redis, and Prometheus services:

```sh
make docker-up
curl http://localhost:8080/health
```

Useful commands:

```sh
make run
make build
make test
make swagger
make docker-logs
make docker-down
```

`make run` expects PostgreSQL and Redis to be available and the required
variables in `.env` to be set.

## Project layout

- `cmd/api/` - API application entry point
- `cmd/atlas-loader/` - Atlas schema loader
- `internal/handler/` - HTTP handlers and routing
- `internal/middleware/` - HTTP middleware
- `internal/repository/` - database repositories
- `internal/service/` - application services
- `internal/model/` - GORM models
- `internal/dto/` - request and response types
- `internal/cache/` - Redis caches and locking
- `pkg/jwt/` - JWT and refresh-token helpers
- `tests/` - repository and service tests
