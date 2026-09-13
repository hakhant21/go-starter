#!/usr/bin/env bash
set -euo pipefail

DEFAULT_GITHUB_URL="https://github.com/hakhant21/go-starter.git"
GITHUB_URL="$DEFAULT_GITHUB_URL"

if [[ -r /dev/tty ]]; then
  while :; do
    read -r -p "GitHub URL [$DEFAULT_GITHUB_URL]: " GITHUB_INPUT </dev/tty || exit 1
    GITHUB_INPUT="${GITHUB_INPUT:-$DEFAULT_GITHUB_URL}"
    GITHUB_INPUT="${GITHUB_INPUT%/}"

    # Only accept a GitHub repository URL.
    if [[ ! "$GITHUB_INPUT" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(\.git)?$ ]]; then
      printf '%s\n' 'GitHub URL must look like https://github.com/owner/repo or https://github.com/owner/repo.git'
      continue
    fi

    GITHUB_URL="$GITHUB_INPUT"
    break
  done
fi

write_01_docs_docs_go() {
cat > docs/docs.go <<'EOF'
package docs

import "github.com/swaggo/swag"

const docTemplate = `{
    "swagger": "2.0",
    "info": {
        "title": "Starter API",
        "description": "Gin + GORM REST API starter.",
        "version": "1.0"
    },
    "basePath": "/api/v1",
    "securityDefinitions": {
        "BearerAuth": {
            "type": "apiKey",
            "name": "Authorization",
            "in": "header"
        }
    },
    "paths": {}
}`

var SwaggerInfo = &swag.Spec{
	Version:          "1.0",
	BasePath:         "/api/v1",
	Title:            "Starter API",
	Description:      "Gin + GORM REST API starter.",
	InfoInstanceName: "swagger",
	SwaggerTemplate:  docTemplate,
}

func init() {
	swag.Register(SwaggerInfo.InstanceName(), SwaggerInfo)
}
EOF
}

write_02_go_mod() {
cat > go.mod <<EOF
module ${MODULE}

go 1.26
EOF
}

write_03__gitignore() {
cat > .gitignore <<'EOF'
.env
.env.local
*.exe
*.out
*.test
bin/
tmp/
coverage.out
coverage.html
/docs/
!/docs/.gitkeep
!/docs/docs.go
EOF
}

write_04__dockerignore() {
cat > .dockerignore <<'EOF'
.git
.env
*.md
bin/
tmp/
coverage.*
EOF
}

write_05__env_example() {
cat > .env.example <<'EOF'
ENV=development
PORT=8080

DATABASE_URL=host=localhost user=postgres password=postgres dbname=starter port=5432 sslmode=disable
REDIS_URL=redis://localhost:6379/0

JWT_SECRET=change-me-in-production
JWT_EXPIRY_HOURS=24
REFRESH_TTL_HOURS=720

APP_BASE_URL=http://localhost:3000
ALLOWED_ORIGINS=http://localhost:3000,http://localhost:5173

SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASS=
SMTP_FROM=no-reply@example.com

BOOTSTRAP_ADMIN_EMAIL=
EOF
}

write_06_Makefile() {
cat > Makefile <<'EOF'
.PHONY: run build test test-cover tidy swagger migrate-diff migrate-apply \
        migrate-status docker-up docker-down docker-logs docker-reset

run:
	go run ./cmd/api

build:
	go build -ldflags="-s -w" -o bin/api ./cmd/api

test:
	go test ./tests/... -race -count=1

test-cover:
	go test ./tests/... -race -coverprofile=coverage.out -covermode=atomic
	go tool cover -html=coverage.out -o coverage.html

test-all:
	go test ./... -race -count=1

tidy:
	go mod tidy

swagger:
	go run github.com/swaggo/swag/cmd/swag@v1.16.6 init -g cmd/api/main.go -o docs --parseDependency --parseInternal

migrate-diff:
	atlas migrate diff $(name) --env local

migrate-apply:
	atlas migrate apply --env local --url "postgres://postgres:postgres@localhost:5432/starter?sslmode=disable"

migrate-status:
	atlas migrate status --env local --url "postgres://postgres:postgres@localhost:5432/starter?sslmode=disable"

docker-up:
	docker compose up -d --build

docker-down:
	docker compose down

docker-logs:
	docker compose logs -f api

docker-reset:
	docker compose down -v
	docker compose up -d --build
EOF
}

write_07_Dockerfile() {
cat > Dockerfile <<'EOF'
FROM golang:1.26-alpine AS builder

WORKDIR /app
RUN apk add --no-cache git

COPY go.mod go.sum* ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/api ./cmd/api

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata wget && adduser -D -u 1000 app
WORKDIR /app
COPY --from=builder /out/api /app/api
USER app
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:8080/health || exit 1
ENTRYPOINT ["/app/api"]
EOF
}

write_08_docker_compose_yml() {
cat > docker-compose.yml <<'EOF'
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: starter
    ports: ["5432:5432"]
    volumes: [pgdata:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      retries: 10

  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s

  api:
    build: .
    ports: ["8080:8080"]
    environment:
      ENV: production
      PORT: 8080
      DATABASE_URL: host=postgres user=postgres password=postgres dbname=starter port=5432 sslmode=disable
      REDIS_URL: redis://redis:6379/0
      JWT_SECRET: ${JWT_SECRET:-change-me-in-prod-please}
      ALLOWED_ORIGINS: http://localhost:3000
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_healthy }
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:latest
    ports: ["9090:9090"]
    volumes:
      - ./observability/prometheus.yml:/etc/prometheus/prometheus.yml
      - promdata:/prometheus

volumes:
  pgdata:
  promdata:
EOF
}

write_09_observability_prometheus_yml() {
cat > observability/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: starter-api
    static_configs:
      - targets: ["api:8080"]
    metrics_path: /metrics
EOF
}

write_10_atlas_hcl() {
cat > atlas.hcl <<'EOF'
data "external_schema" "gorm" {
  program = ["go", "run", "./cmd/atlas-loader"]
}

env "local" {
  src = data.external_schema.gorm.url
  dev = "docker://postgres/16/dev?search_path=public"
  migration {
    dir = "file://internal/database/migrations"
  }
}
EOF
}

write_11__golangci_yml() {
cat > .golangci.yml <<'EOF'
run:
  timeout: 5m
  tests: true

linters:
  enable:
    - errcheck
    - gosimple
    - govet
    - ineffassign
    - staticcheck
    - unused
    - gofmt
    - goimports
    - misspell
    - revive
    - unconvert
    - unparam
    - gocritic
    - bodyclose
    - noctx
    - sqlclosecheck
    - gosec
    - goconst
    - prealloc
    - whitespace

linters-settings:
  govet:
    enable-all: true
  revive:
    rules:
      - name: exported
        disabled: true
  gosec:
    excludes:
      - G404

issues:
  exclude-rules:
    - path: _test\.go
      linters: [gosec, dupl, errcheck]
    - path: cmd/
      linters: [unparam]
EOF
}

write_12_pkg_jwt_jwt_go() {
cat > pkg/jwt/jwt.go <<'EOF'
package jwt

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var ErrInvalidToken = errors.New("invalid token")

type Claims struct {
	UserID uint   `json:"user_id"`
	Email  string `json:"email"`
	jwt.RegisteredClaims
}

func Generate(userID uint, email, secret string, expirySeconds int64) (string, error) {
	claims := Claims{
		UserID: userID,
		Email:  email,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Duration(expirySeconds) * time.Second)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(secret))
}

func Parse(tokenStr, secret string) (*Claims, error) {
	token, err := jwt.ParseWithClaims(tokenStr, &Claims{}, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, ErrInvalidToken
		}
		return []byte(secret), nil
	})
	if err != nil {
		return nil, ErrInvalidToken
	}
	claims, ok := token.Claims.(*Claims)
	if !ok || !token.Valid {
		return nil, ErrInvalidToken
	}
	return claims, nil
}

func GenerateRefreshToken() (raw string, hash string, err error) {
	b := make([]byte, 32)
	if _, err = rand.Read(b); err != nil {
		return "", "", err
	}
	raw = base64.RawURLEncoding.EncodeToString(b)
	return raw, HashToken(raw), nil
}

func HashToken(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}
EOF
}

write_13_internal_config_config_go() {
cat > internal/config/config.go <<'EOF'
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/joho/godotenv"
)

type Config struct {
	Env            string
	Port           string
	DatabaseURL    string
	RedisURL       string
	JWTSecret      string
	JWTExpiry      time.Duration
	RefreshTTL     time.Duration
	AppBaseURL     string
	AllowedOrigins []string
	SMTPHost       string
	SMTPPort       string
	SMTPUser       string
	SMTPPass       string
	SMTPFrom       string
	BootstrapAdmin string
}

func Load() (*Config, error) {
	_ = godotenv.Load()

	expiry, err := strconv.Atoi(getEnv("JWT_EXPIRY_HOURS", "24"))
	if err != nil {
		return nil, fmt.Errorf("invalid JWT_EXPIRY_HOURS: %w", err)
	}
	refresh, err := strconv.Atoi(getEnv("REFRESH_TTL_HOURS", "720"))
	if err != nil {
		return nil, fmt.Errorf("invalid REFRESH_TTL_HOURS: %w", err)
	}

	cfg := &Config{
		Env:            getEnv("ENV", "development"),
		Port:           getEnv("PORT", "8080"),
		DatabaseURL:    getEnv("DATABASE_URL", ""),
		RedisURL:       getEnv("REDIS_URL", "redis://localhost:6379/0"),
		JWTSecret:      getEnv("JWT_SECRET", ""),
		JWTExpiry:      time.Duration(expiry) * time.Hour,
		RefreshTTL:     time.Duration(refresh) * time.Hour,
		AppBaseURL:     getEnv("APP_BASE_URL", "http://localhost:3000"),
		AllowedOrigins: splitCSV(getEnv("ALLOWED_ORIGINS", "http://localhost:3000")),
		SMTPHost:       getEnv("SMTP_HOST", ""),
		SMTPPort:       getEnv("SMTP_PORT", "587"),
		SMTPUser:       getEnv("SMTP_USER", ""),
		SMTPPass:       getEnv("SMTP_PASS", ""),
		SMTPFrom:       getEnv("SMTP_FROM", "no-reply@example.com"),
		BootstrapAdmin: getEnv("BOOTSTRAP_ADMIN_EMAIL", ""),
	}

	if cfg.DatabaseURL == "" {
		return nil, fmt.Errorf("DATABASE_URL is required")
	}
	if cfg.JWTSecret == "" {
		return nil, fmt.Errorf("JWT_SECRET is required")
	}
	return cfg, nil
}

func (c *Config) IsProduction() bool { return c.Env == "production" }

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func splitCSV(s string) []string {
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if t := strings.TrimSpace(p); t != "" {
			out = append(out, t)
		}
	}
	return out
}
EOF
}

write_14_internal_database_database_go() {
cat > internal/database/database.go <<'EOF'
package database

import (
	"fmt"
	"time"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"__GO_MODULE__/internal/model"
)

func New(dsn string, isProd bool) (*gorm.DB, error) {
	lvl := logger.Info
	if isProd {
		lvl = logger.Warn
	}

	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{
		Logger:                 logger.Default.LogMode(lvl),
		SkipDefaultTransaction: true,
		PrepareStmt:            true,
		NowFunc:                func() time.Time { return time.Now().UTC() },
	})
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}

	sqlDB, err := db.DB()
	if err != nil {
		return nil, err
	}
	sqlDB.SetMaxOpenConns(25)
	sqlDB.SetMaxIdleConns(5)
	sqlDB.SetConnMaxLifetime(5 * time.Minute)

	if err := sqlDB.Ping(); err != nil {
		return nil, fmt.Errorf("ping db: %w", err)
	}
	return db, nil
}

func AutoMigrate(db *gorm.DB) error {
	return db.AutoMigrate(
		&model.User{},
		&model.RefreshToken{},
		&model.OneTimeToken{},
		&model.Role{},
		&model.Permission{},
	)
}
EOF
}

write_15_internal_database_seed_go() {
cat > internal/database/seed.go <<'EOF'
package database

import (
	"log/slog"

	"gorm.io/gorm"

	"__GO_MODULE__/internal/model"
	"__GO_MODULE__/internal/rbac"
)

func SeedRBAC(db *gorm.DB) error {
	permSet := map[string]struct{}{}
	for _, perms := range rbac.DefaultRoles {
		for _, p := range perms {
			permSet[p] = struct{}{}
		}
	}

	for name := range permSet {
		var existing model.Permission
		if err := db.Where("name = ?", name).First(&existing).Error; err == nil {
			continue
		}
		if err := db.Create(&model.Permission{Name: name}).Error; err != nil {
			return err
		}
	}

	for roleName, permNames := range rbac.DefaultRoles {
		var role model.Role
		if err := db.Where("name = ?", roleName).First(&role).Error; err != nil {
			role = model.Role{Name: roleName, Description: roleName + " role"}
			if err := db.Create(&role).Error; err != nil {
				return err
			}
		}
		var perms []model.Permission
		if err := db.Where("name IN ?", permNames).Find(&perms).Error; err != nil {
			return err
		}
		if err := db.Model(&role).Association("Permissions").Replace(perms); err != nil {
			return err
		}
	}

	slog.Info("RBAC seeded")
	return nil
}
EOF
}

write_16_internal_rbac_permissions_go() {
cat > internal/rbac/permissions.go <<'EOF'
package rbac

const (
	PermUsersRead   = "users:read"
	PermUsersWrite  = "users:write"
	PermUsersDelete = "users:delete"

	PermRolesManage = "roles:manage"
)

var DefaultRoles = map[string][]string{
	"user": {
		PermUsersRead,
	},
	"moderator": {
		PermUsersRead,
		PermUsersWrite,
	},
	"admin": {
		PermUsersRead, PermUsersWrite, PermUsersDelete,
		PermRolesManage,
	},
}
EOF
}

write_17_internal_model_user_go() {
cat > internal/model/user.go <<'EOF'
package model

import (
	"time"

	"gorm.io/gorm"
)

type User struct {
	ID              uint           `gorm:"primaryKey" json:"id"`
	Name            string         `gorm:"size:100;not null" json:"name"`
	Email           string         `gorm:"size:255;uniqueIndex;not null" json:"email"`
	Password        string         `gorm:"size:255;not null" json:"-"`
	Active          bool           `gorm:"default:true" json:"active"`
	EmailVerified   bool           `gorm:"default:false" json:"email_verified"`
	EmailVerifiedAt *time.Time     `json:"-"`
	Roles           []Role         `gorm:"many2many:user_roles;" json:"roles,omitempty"`
	CreatedAt       time.Time      `json:"created_at"`
	UpdatedAt       time.Time      `json:"updated_at"`
	DeletedAt       gorm.DeletedAt `gorm:"index" json:"-"`
}
EOF
}

write_18_internal_model_refresh_token_go() {
cat > internal/model/refresh_token.go <<'EOF'
package model

import "time"

type RefreshToken struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	UserID    uint      `gorm:"index;not null" json:"user_id"`
	TokenHash string    `gorm:"size:64;uniqueIndex;not null" json:"-"`
	ExpiresAt time.Time `gorm:"index;not null" json:"expires_at"`
	Revoked   bool      `gorm:"default:false" json:"revoked"`
	CreatedAt time.Time `json:"created_at"`
}
EOF
}

write_19_internal_model_token_go() {
cat > internal/model/token.go <<'EOF'
package model

import "time"

type TokenType string

const (
	TokenTypeEmailVerify   TokenType = "email_verify"
	TokenTypePasswordReset TokenType = "password_reset"
)

type OneTimeToken struct {
	ID        uint       `gorm:"primaryKey" json:"id"`
	UserID    uint       `gorm:"index;not null" json:"user_id"`
	TokenHash string     `gorm:"size:64;uniqueIndex;not null" json:"-"`
	Type      TokenType  `gorm:"size:32;index;not null" json:"type"`
	ExpiresAt time.Time  `gorm:"index;not null" json:"expires_at"`
	UsedAt    *time.Time `json:"used_at"`
	CreatedAt time.Time  `json:"created_at"`
}
EOF
}

write_20_internal_model_role_go() {
cat > internal/model/role.go <<'EOF'
package model

import "time"

type Role struct {
	ID          uint         `gorm:"primaryKey" json:"id"`
	Name        string       `gorm:"size:50;uniqueIndex;not null" json:"name"`
	Description string       `gorm:"size:255" json:"description"`
	Permissions []Permission `gorm:"many2many:role_permissions;" json:"permissions,omitempty"`
	CreatedAt   time.Time    `json:"created_at"`
	UpdatedAt   time.Time    `json:"updated_at"`
}

type Permission struct {
	ID          uint      `gorm:"primaryKey" json:"id"`
	Name        string    `gorm:"size:100;uniqueIndex;not null" json:"name"`
	Description string    `gorm:"size:255" json:"description"`
	CreatedAt   time.Time `json:"created_at"`
}
EOF
}

write_21_internal_dto_user_go() {
cat > internal/dto/user.go <<'EOF'
package dto

import (
	"time"

	"__GO_MODULE__/internal/model"
)

type CreateUserRequest struct {
	Name     string `json:"name"     validate:"required,min=2,max=100"`
	Email    string `json:"email"    validate:"required,email"`
	Password string `json:"password" validate:"required,min=8"`
}

type UpdateUserRequest struct {
	Name  *string `json:"name,omitempty"  validate:"omitempty,min=2,max=100"`
	Email *string `json:"email,omitempty" validate:"omitempty,email"`
}

type UserResponse struct {
	ID            uint     `json:"id"`
	Name          string   `json:"name"`
	Email         string   `json:"email"`
	Active        bool     `json:"active"`
	EmailVerified bool     `json:"email_verified"`
	Roles         []string `json:"roles,omitempty"`
	Permissions   []string `json:"permissions,omitempty"`
	CreatedAt     string   `json:"created_at"`
}

type ListUsersQuery struct {
	Page  int `form:"page"  validate:"omitempty,min=1"`
	Limit int `form:"limit" validate:"omitempty,min=1,max=100"`
}

func UserToResponse(u *model.User) *UserResponse {
	if u == nil {
		return nil
	}
	roles := make([]string, 0, len(u.Roles))
	for _, r := range u.Roles {
		roles = append(roles, r.Name)
	}
	return &UserResponse{
		ID:            u.ID,
		Name:          u.Name,
		Email:         u.Email,
		Active:        u.Active,
		EmailVerified: u.EmailVerified,
		Roles:         roles,
		CreatedAt:     u.CreatedAt.Format(time.RFC3339),
	}
}
EOF
}

write_22_internal_dto_auth_go() {
cat > internal/dto/auth.go <<'EOF'
package dto

type LoginRequest struct {
	Email    string `json:"email"    validate:"required,email"`
	Password string `json:"password" validate:"required"`
}

type AuthResponse struct {
	Token        string        `json:"token"`
	RefreshToken string        `json:"refresh_token"`
	User         *UserResponse `json:"user"`
}

type RefreshRequest struct {
	RefreshToken string `json:"refresh_token" validate:"required"`
}

type ForgotPasswordRequest struct {
	Email string `json:"email" validate:"required,email"`
}

type ResetPasswordRequest struct {
	Token       string `json:"token"        validate:"required"`
	NewPassword string `json:"new_password" validate:"required,min=8"`
}

type VerifyEmailRequest struct {
	Token string `json:"token" validate:"required"`
}

type ResendVerificationRequest struct {
	Email string `json:"email" validate:"required,email"`
}
EOF
}

write_23_internal_dto_admin_go() {
cat > internal/dto/admin.go <<'EOF'
package dto

type AdminUserResponse struct {
	ID            uint     `json:"id"`
	Name          string   `json:"name"`
	Email         string   `json:"email"`
	Active        bool     `json:"active"`
	EmailVerified bool     `json:"email_verified"`
	Roles         []string `json:"roles"`
	Permissions   []string `json:"permissions"`
	CreatedAt     string   `json:"created_at"`
}

type ListAdminUsersQuery struct {
	Page     int    `form:"page"   validate:"omitempty,min=1"`
	Limit    int    `form:"limit"  validate:"omitempty,min=1,max=100"`
	Search   string `form:"search" validate:"omitempty,max=100"`
	RoleName string `form:"role"   validate:"omitempty,max=50"`
	Active   *bool  `form:"active"`
}

type AssignRoleRequest struct {
	RoleName string `json:"role_name" validate:"required,max=50"`
}

type CreateRoleRequest struct {
	Name        string   `json:"name"        validate:"required,min=2,max=50"`
	Description string   `json:"description" validate:"omitempty,max=255"`
	Permissions []string `json:"permissions" validate:"omitempty,dive,max=100"`
}

type SetRolePermissionsRequest struct {
	Permissions []string `json:"permissions" validate:"required,dive,max=100"`
}

type CreatePermissionRequest struct {
	Name        string `json:"name"        validate:"required,min=2,max=100"`
	Description string `json:"description" validate:"omitempty,max=255"`
}

type RoleResponse struct {
	ID          uint     `json:"id"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Permissions []string `json:"permissions"`
}

type PermissionResponse struct {
	ID          uint   `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
}

type SetActiveRequest struct {
	Active bool `json:"active"`
}
EOF
}

write_24_internal_email_email_go() {
cat > internal/email/email.go <<'EOF'
package email

import "context"

type Message struct {
	To      string
	Subject string
	Body    string
}

type Sender interface {
	Send(ctx context.Context, msg Message) error
}
EOF
}

write_25_internal_email_console_go() {
cat > internal/email/console.go <<'EOF'
package email

import (
	"context"
	"log/slog"
)

type ConsoleSender struct{}

func NewConsoleSender() *ConsoleSender { return &ConsoleSender{} }

func (s *ConsoleSender) Send(_ context.Context, msg Message) error {
	slog.Info("EMAIL",
		"to", msg.To,
		"subject", msg.Subject,
		"body", msg.Body,
	)
	return nil
}
EOF
}

write_26_internal_email_smtp_go() {
cat > internal/email/smtp.go <<'EOF'
package email

import (
	"context"
	"fmt"
	"net/smtp"
)

type SMTPSender struct {
	Host, Port, Username, Password, From string
}

func NewSMTPSender(host, port, user, pass, from string) *SMTPSender {
	return &SMTPSender{Host: host, Port: port, Username: user, Password: pass, From: from}
}

func (s *SMTPSender) Send(_ context.Context, msg Message) error {
	auth := smtp.PlainAuth("", s.Username, s.Password, s.Host)
	headers := fmt.Sprintf(
		"From: %s\r\nTo: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=\"utf-8\"\r\n\r\n",
		s.From, msg.To, msg.Subject,
	)
	return smtp.SendMail(s.Host+":"+s.Port, auth, s.From, []string{msg.To}, []byte(headers+msg.Body))
}
EOF
}

write_27_internal_metrics_metrics_go() {
cat > internal/metrics/metrics.go <<'EOF'
package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	HTTPRequestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{Name: "http_requests_total", Help: "Total HTTP requests."},
		[]string{"method", "route", "status"},
	)
	HTTPRequestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request duration.",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"method", "route"},
	)
	CacheHits = promauto.NewCounterVec(
		prometheus.CounterOpts{Name: "cache_hits_total", Help: "Cache hits."},
		[]string{"cache"},
	)
	CacheMisses = promauto.NewCounterVec(
		prometheus.CounterOpts{Name: "cache_misses_total", Help: "Cache misses."},
		[]string{"cache"},
	)
	SingleflightShared = promauto.NewCounterVec(
		prometheus.CounterOpts{Name: "singleflight_shared_total", Help: "Shared calls."},
		[]string{"key_prefix"},
	)
	SingleflightLoads = promauto.NewCounterVec(
		prometheus.CounterOpts{Name: "singleflight_loads_total", Help: "Loads triggered."},
		[]string{"key_prefix"},
	)
)
EOF
}

write_28_internal_cache_redis_go() {
cat > internal/cache/redis.go <<'EOF'
package cache

import (
	"context"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

func NewRedis(url string) (*redis.Client, error) {
	opts, err := redis.ParseURL(url)
	if err != nil {
		return nil, fmt.Errorf("parse redis url: %w", err)
	}
	client := redis.NewClient(opts)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := client.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("ping redis: %w", err)
	}
	return client, nil
}
EOF
}

write_29_internal_cache_rbac_go() {
cat > internal/cache/rbac.go <<'EOF'
package cache

import (
	"context"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	rbacPermBaseTTL = 60 * time.Second
	rbacPermJitter  = 20 * time.Second
)

type RBACCache struct{ rdb *redis.Client }

func NewRBACCache(rdb *redis.Client) *RBACCache { return &RBACCache{rdb: rdb} }

func (c *RBACCache) key(userID uint) string { return fmt.Sprintf("rbac:perms:%d", userID) }

func (c *RBACCache) Get(ctx context.Context, userID uint) ([]string, bool) {
	raw, err := c.rdb.Get(ctx, c.key(userID)).Bytes()
	if err != nil {
		return nil, false
	}
	var perms []string
	if err := json.Unmarshal(raw, &perms); err != nil {
		return nil, false
	}
	return perms, true
}

func (c *RBACCache) Set(ctx context.Context, userID uint, perms []string) {
	raw, _ := json.Marshal(perms)
	ttl := rbacPermBaseTTL + time.Duration(rand.Int64N(int64(rbacPermJitter)))
	_ = c.rdb.Set(ctx, c.key(userID), raw, ttl).Err()
}

func (c *RBACCache) Invalidate(ctx context.Context, userID uint) {
	_ = c.rdb.Del(ctx, c.key(userID)).Err()
}

func (c *RBACCache) InvalidateUsers(ctx context.Context, userIDs []uint) {
	if len(userIDs) == 0 {
		return
	}
	keys := make([]string, len(userIDs))
	for i, id := range userIDs {
		keys[i] = c.key(id)
	}
	_ = c.rdb.Del(ctx, keys...).Err()
}
EOF
}

write_30_internal_cache_user_go() {
cat > internal/cache/user.go <<'EOF'
package cache

import (
	"context"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"time"

	"github.com/redis/go-redis/v9"

	"__GO_MODULE__/internal/model"
)

const (
	userBaseTTL = 5 * time.Minute
	userJitter  = 30 * time.Second
)

type UserCache struct{ rdb *redis.Client }

func NewUserCache(rdb *redis.Client) *UserCache { return &UserCache{rdb: rdb} }

func (c *UserCache) key(id uint) string { return fmt.Sprintf("user:%d", id) }

func (c *UserCache) Get(ctx context.Context, id uint) (*model.User, bool) {
	raw, err := c.rdb.Get(ctx, c.key(id)).Bytes()
	if err != nil {
		return nil, false
	}
	var u model.User
	if err := json.Unmarshal(raw, &u); err != nil {
		return nil, false
	}
	return &u, true
}

func (c *UserCache) Set(ctx context.Context, u *model.User) {
	raw, _ := json.Marshal(u)
	ttl := userBaseTTL + time.Duration(rand.Int64N(int64(userJitter)))
	_ = c.rdb.Set(ctx, c.key(u.ID), raw, ttl).Err()
}

func (c *UserCache) Invalidate(ctx context.Context, id uint) {
	_ = c.rdb.Del(ctx, c.key(id)).Err()
}
EOF
}

write_31_internal_cache_singleflight_go() {
cat > internal/cache/singleflight.go <<'EOF'
package cache

import (
	"context"
	"strings"

	"golang.org/x/sync/singleflight"

	"__GO_MODULE__/internal/metrics"
)

type LoaderFunc[T any] func(ctx context.Context) (T, error)

func GetOrLoad[T any](
	ctx context.Context,
	group *singleflight.Group,
	key string,
	get func(ctx context.Context) (T, bool),
	set func(ctx context.Context, v T),
	load LoaderFunc[T],
) (T, error) {
	prefix := keyPrefix(key)

	if v, ok := get(ctx); ok {
		metrics.CacheHits.WithLabelValues(prefix).Inc()
		return v, nil
	}
	metrics.CacheMisses.WithLabelValues(prefix).Inc()

	v, err, shared := group.Do(key, func() (any, error) {
		if v, ok := get(ctx); ok {
			return v, nil
		}
		metrics.SingleflightLoads.WithLabelValues(prefix).Inc()
		loaded, err := load(ctx)
		if err != nil {
			return nil, err
		}
		set(ctx, loaded)
		return loaded, nil
	})
	if err != nil {
		var zero T
		return zero, err
	}
	if shared {
		metrics.SingleflightShared.WithLabelValues(prefix).Inc()
	}
	return v.(T), nil
}

func keyPrefix(key string) string {
	if i := strings.Index(key, ":"); i > 0 {
		return key[:i]
	}
	return key
}
EOF
}

write_32_internal_cache_lock_go() {
cat > internal/cache/lock.go <<'EOF'
package cache

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"time"

	"github.com/redis/go-redis/v9"
)

var ErrLockTimeout = errors.New("lock acquisition timeout")

type Lock struct{ rdb *redis.Client }

func NewLock(rdb *redis.Client) *Lock { return &Lock{rdb: rdb} }

func (l *Lock) Acquire(ctx context.Context, key string, ttl, wait time.Duration) (func(), error) {
	token := randomToken()
	deadline := time.Now().Add(wait)

	for {
		ok, err := l.rdb.SetNX(ctx, key, token, ttl).Result()
		if err != nil {
			return nil, err
		}
		if ok {
			return func() { l.release(context.Background(), key, token) }, nil
		}
		if time.Now().After(deadline) {
			return nil, ErrLockTimeout
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func (l *Lock) release(ctx context.Context, key, token string) {
	script := `
		if redis.call("get", KEYS[1]) == ARGV[1] then
			return redis.call("del", KEYS[1])
		else
			return 0
		end`
	_ = l.rdb.Eval(ctx, script, []string{key}, token).Err()
}

func randomToken() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
EOF
}

write_33_internal_repository_errors_go() {
cat > internal/repository/errors.go <<'EOF'
package repository

import "errors"

var ErrNotFound = errors.New("record not found")
EOF
}

write_34_internal_repository_user_user_go() {
cat > internal/repository/user/user.go <<'EOF'
package user

import (
	"context"
	"errors"
	"fmt"
	"time"

	"gorm.io/gorm"

	"__GO_MODULE__/internal/model"
	"__GO_MODULE__/internal/repository"
)

type Filter struct {
	Search   string
	RoleName string
	Active   *bool
	Limit    int
	Offset   int
}

type Repository interface {
	Create(ctx context.Context, u *model.User) error
	GetByID(ctx context.Context, id uint) (*model.User, error)
	GetByEmail(ctx context.Context, email string) (*model.User, error)
	List(ctx context.Context, limit, offset int) ([]model.User, int64, error)
	ListFiltered(ctx context.Context, f Filter) ([]model.User, int64, error)
	Update(ctx context.Context, u *model.User) error
	Delete(ctx context.Context, id uint) error
	SetActive(ctx context.Context, id uint, active bool) error
	SetEmailVerified(ctx context.Context, userID uint, verifiedAt time.Time) error
	UpdatePassword(ctx context.Context, userID uint, passwordHash string) error
}

type repo struct{ db *gorm.DB }

func New(db *gorm.DB) Repository { return &repo{db: db} }

func (r *repo) Create(ctx context.Context, u *model.User) error {
	return r.db.WithContext(ctx).Create(u).Error
}

func (r *repo) GetByID(ctx context.Context, id uint) (*model.User, error) {
	var u model.User
	err := r.db.WithContext(ctx).First(&u, id).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, repository.ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("get user %d: %w", id, err)
	}
	return &u, nil
}

func (r *repo) GetByEmail(ctx context.Context, email string) (*model.User, error) {
	var u model.User
	err := r.db.WithContext(ctx).Where("email = ?", email).First(&u).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, repository.ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("get user by email: %w", err)
	}
	return &u, nil
}

func (r *repo) List(ctx context.Context, limit, offset int) ([]model.User, int64, error) {
	var (
		users []model.User
		total int64
	)
	q := r.db.WithContext(ctx).Model(&model.User{})
	if err := q.Count(&total).Error; err != nil {
		return nil, 0, err
	}
	if err := q.Order("created_at DESC").Limit(limit).Offset(offset).Find(&users).Error; err != nil {
		return nil, 0, err
	}
	return users, total, nil
}

func (r *repo) ListFiltered(ctx context.Context, f Filter) ([]model.User, int64, error) {
	q := r.db.WithContext(ctx).Model(&model.User{})
	if f.Search != "" {
		like := "%" + f.Search + "%"
		q = q.Where("name ILIKE ? OR email ILIKE ?", like, like)
	}
	if f.Active != nil {
		q = q.Where("active = ?", *f.Active)
	}
	if f.RoleName != "" {
		q = q.Joins("JOIN user_roles ur ON ur.user_id = users.id").
			Joins("JOIN roles r ON r.id = ur.role_id").
			Where("r.name = ?", f.RoleName).
			Distinct("users.*")
	}
	var total int64
	if err := q.Count(&total).Error; err != nil {
		return nil, 0, err
	}
	var users []model.User
	if err := q.Order("users.created_at DESC").Limit(f.Limit).Offset(f.Offset).Find(&users).Error; err != nil {
		return nil, 0, err
	}
	return users, total, nil
}

func (r *repo) Update(ctx context.Context, u *model.User) error {
	return r.db.WithContext(ctx).Save(u).Error
}

func (r *repo) Delete(ctx context.Context, id uint) error {
	res := r.db.WithContext(ctx).Delete(&model.User{}, id)
	if res.Error != nil {
		return res.Error
	}
	if res.RowsAffected == 0 {
		return repository.ErrNotFound
	}
	return nil
}

func (r *repo) SetActive(ctx context.Context, id uint, active bool) error {
	res := r.db.WithContext(ctx).Model(&model.User{}).Where("id = ?", id).Update("active", active)
	if res.Error != nil {
		return res.Error
	}
	if res.RowsAffected == 0 {
		return repository.ErrNotFound
	}
	return nil
}

func (r *repo) SetEmailVerified(ctx context.Context, userID uint, verifiedAt time.Time) error {
	return r.db.WithContext(ctx).Model(&model.User{}).Where("id = ?", userID).
		Updates(map[string]any{"email_verified": true, "email_verified_at": verifiedAt}).Error
}

func (r *repo) UpdatePassword(ctx context.Context, userID uint, passwordHash string) error {
	return r.db.WithContext(ctx).Model(&model.User{}).Where("id = ?", userID).
		Update("password", passwordHash).Error
}
EOF
}

write_35_internal_repository_token_token_go() {
cat > internal/repository/token/token.go <<'EOF'
package token

import (
	"context"
	"errors"
	"fmt"
	"time"

	"gorm.io/gorm"

	"__GO_MODULE__/internal/model"
	"__GO_MODULE__/internal/repository"
)

type Repository interface {
	Create(ctx context.Context, t *model.OneTimeToken) error
	GetValid(ctx context.Context, hash string, typ model.TokenType) (*model.OneTimeToken, error)
	MarkUsed(ctx context.Context, id uint) error
	InvalidateAllForUser(ctx context.Context, userID uint, typ model.TokenType) error
	DeleteExpired(ctx context.Context) error
}

type repo struct{ db *gorm.DB }

func New(db *gorm.DB) Repository { return &repo{db: db} }

func (r *repo) Create(ctx context.Context, t *model.OneTimeToken) error {
	return r.db.WithContext(ctx).Create(t).Error
}

func (r *repo) GetValid(ctx context.Context, hash string, typ model.TokenType) (*model.OneTimeToken, error) {
	var t model.OneTimeToken
	err := r.db.WithContext(ctx).
		Where("token_hash = ? AND type = ? AND used_at IS NULL AND expires_at > ?", hash, typ, time.Now()).
		First(&t).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, repository.ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("get token: %w", err)
	}
	return &t, nil
}

func (r *repo) MarkUsed(ctx context.Context, id uint) error {
	return r.db.WithContext(ctx).Model(&model.OneTimeToken{}).Where("id = ?", id).
		Update("used_at", time.Now()).Error
}

func (r *repo) InvalidateAllForUser(ctx context.Context, userID uint, typ model.TokenType) error {
	return r.db.WithContext(ctx).Model(&model.OneTimeToken{}).
		Where("user_id = ? AND type = ? AND used_at IS NULL", userID, typ).
		Update("used_at", time.Now()).Error
}

func (r *repo) DeleteExpired(ctx context.Context) error {
	return r.db.WithContext(ctx).Where("expires_at < ?", time.Now()).Delete(&model.OneTimeToken{}).Error
}
EOF
}

write_36_internal_repository_refresh_token_refresh_token_go() {
cat > internal/repository/refresh_token/refresh_token.go <<'EOF'
package refreshtoken

import (
	"context"
	"errors"
	"fmt"
	"time"

	"gorm.io/gorm"

	"__GO_MODULE__/internal/model"
	"__GO_MODULE__/internal/repository"
)

type Repository interface {
	Create(ctx context.Context, rt *model.RefreshToken) error
	GetByHash(ctx context.Context, hash string) (*model.RefreshToken, error)
	Revoke(ctx context.Context, hash string) error
	RevokeAllForUser(ctx context.Context, userID uint) error
	DeleteExpired(ctx context.Context) error
}

type repo struct{ db *gorm.DB }

func New(db *gorm.DB) Repository { return &repo{db: db} }

func (r *repo) Create(ctx context.Context, rt *model.RefreshToken) error {
	return r.db.WithContext(ctx).Create(rt).Error
}

func (r *repo) GetByHash(ctx context.Context, hash string) (*model.RefreshToken, error) {
	var rt model.RefreshToken
	err := r.db.WithContext(ctx).Where("token_hash = ?", hash).First(&rt).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, repository.ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("get refresh token: %w", err)
	}
	return &rt, nil
}

func (r *repo) Revoke(ctx context.Context, hash string) error {
	return r.db.WithContext(ctx).Model(&model.RefreshToken{}).
		Where("token_hash = ?", hash).Update("revoked", true).Error
}

func (r *repo) RevokeAllForUser(ctx context.Context, userID uint) error {
	return r.db.WithContext(ctx).Model(&model.RefreshToken{}).
		Where("user_id = ? AND revoked = false", userID).
		Update("revoked", true).Error
}

func (r *repo) DeleteExpired(ctx context.Context) error {
	return r.db.WithContext(ctx).Where("expires_at < ?", time.Now()).Delete(&model.RefreshToken{}).Error
}
EOF
}

write_37_internal_repository_rbac_rbac_go() {
cat > internal/repository/rbac/rbac.go <<'EOF'
package rbac

import (
	"context"
	"fmt"

	"gorm.io/gorm"

	"__GO_MODULE__/internal/model"
)

type Repository interface {
	AssignRoleByName(ctx context.Context, userID uint, roleName string) error
	RevokeRoleByName(ctx context.Context, userID uint, roleName string) error
	GetUserPermissions(ctx context.Context, userID uint) ([]string, error)
	GetUserRoleNames(ctx context.Context, userID uint) ([]string, error)
	ListRoles(ctx context.Context) ([]model.Role, error)
	CreateRole(ctx context.Context, role *model.Role) error
	SetRolePermissionsByName(ctx context.Context, roleName string, permNames []string) ([]uint, error)
	ListPermissions(ctx context.Context) ([]model.Permission, error)
	CreatePermission(ctx context.Context, p *model.Permission) error
}

type repo struct{ db *gorm.DB }

func New(db *gorm.DB) Repository { return &repo{db: db} }

func (r *repo) AssignRoleByName(ctx context.Context, userID uint, roleName string) error {
	var role model.Role
	if err := r.db.WithContext(ctx).Where("name = ?", roleName).First(&role).Error; err != nil {
		return fmt.Errorf("role %q not found: %w", roleName, err)
	}
	user := model.User{ID: userID}
	return r.db.WithContext(ctx).Model(&user).Association("Roles").Append(&role)
}

func (r *repo) RevokeRoleByName(ctx context.Context, userID uint, roleName string) error {
	var role model.Role
	if err := r.db.WithContext(ctx).Where("name = ?", roleName).First(&role).Error; err != nil {
		return fmt.Errorf("role %q not found: %w", roleName, err)
	}
	user := model.User{ID: userID}
	return r.db.WithContext(ctx).Model(&user).Association("Roles").Delete(&role)
}

func (r *repo) GetUserPermissions(ctx context.Context, userID uint) ([]string, error) {
	var perms []string
	err := r.db.WithContext(ctx).
		Table("permissions p").
		Select("DISTINCT p.name").
		Joins("JOIN role_permissions rp ON rp.permission_id = p.id").
		Joins("JOIN user_roles ur ON ur.role_id = rp.role_id").
		Where("ur.user_id = ?", userID).
		Pluck("p.name", &perms).Error
	return perms, err
}

func (r *repo) GetUserRoleNames(ctx context.Context, userID uint) ([]string, error) {
	var names []string
	err := r.db.WithContext(ctx).
		Table("roles r").
		Select("r.name").
		Joins("JOIN user_roles ur ON ur.role_id = r.id").
		Where("ur.user_id = ?", userID).
		Pluck("r.name", &names).Error
	return names, err
}

func (r *repo) ListRoles(ctx context.Context) ([]model.Role, error) {
	var roles []model.Role
	err := r.db.WithContext(ctx).Preload("Permissions").Find(&roles).Error
	return roles, err
}

func (r *repo) CreateRole(ctx context.Context, role *model.Role) error {
	return r.db.WithContext(ctx).Create(role).Error
}

func (r *repo) SetRolePermissionsByName(ctx context.Context, roleName string, permNames []string) ([]uint, error) {
	var role model.Role
	if err := r.db.WithContext(ctx).Where("name = ?", roleName).First(&role).Error; err != nil {
		return nil, fmt.Errorf("role %q not found: %w", roleName, err)
	}
	var perms []model.Permission
	if len(permNames) > 0 {
		if err := r.db.WithContext(ctx).Where("name IN ?", permNames).Find(&perms).Error; err != nil {
			return nil, err
		}
	}
	if err := r.db.WithContext(ctx).Model(&role).Association("Permissions").Replace(perms); err != nil {
		return nil, err
	}
	var userIDs []uint
	if err := r.db.WithContext(ctx).Table("user_roles").
		Where("role_id = ?", role.ID).Pluck("user_id", &userIDs).Error; err != nil {
		return nil, err
	}
	return userIDs, nil
}

func (r *repo) ListPermissions(ctx context.Context) ([]model.Permission, error) {
	var perms []model.Permission
	err := r.db.WithContext(ctx).Order("name").Find(&perms).Error
	return perms, err
}

func (r *repo) CreatePermission(ctx context.Context, p *model.Permission) error {
	return r.db.WithContext(ctx).Create(p).Error
}
EOF
}

write_38_internal_service_errors_go() {
cat > internal/service/errors.go <<'EOF'
package service

import "errors"

var (
	ErrInvalidInput         = errors.New("invalid input")
	ErrEmailTaken           = errors.New("email already taken")
	ErrUnauthorized         = errors.New("unauthorized")
	ErrForbidden            = errors.New("forbidden")
	ErrTokenInvalid         = errors.New("token invalid or expired")
	ErrEmailAlreadyVerified = errors.New("email already verified")
	ErrEmailNotVerified     = errors.New("email not verified")
)
EOF
}

write_39_internal_service_auth_auth_go() {
cat > internal/service/auth/auth.go <<'EOF'
package auth

import (
	"context"
	"errors"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"

	"__GO_MODULE__/internal/dto"
	"__GO_MODULE__/internal/email"
	"__GO_MODULE__/internal/model"
	"__GO_MODULE__/internal/repository"
	refreshtokenrepo "__GO_MODULE__/internal/repository/refresh_token"
	tokenrepo "__GO_MODULE__/internal/repository/token"
	userrepo "__GO_MODULE__/internal/repository/user"
	"__GO_MODULE__/internal/service"
	"__GO_MODULE__/pkg/jwt"
)

type Service struct {
	userRepo     userrepo.Repository
	refreshRepo  refreshtokenrepo.Repository
	tokenRepo    tokenrepo.Repository
	notifier     *Notifier
	secret       string
	accessExpiry int64
	refreshTTL   time.Duration
}

func New(
	userRepo userrepo.Repository,
	refreshRepo refreshtokenrepo.Repository,
	tokenRepo tokenrepo.Repository,
	mailer email.Sender,
	secret string,
	accessExpirySeconds int64,
	refreshTTL time.Duration,
	appBaseURL string,
) *Service {
	return &Service{
		userRepo:     userRepo,
		refreshRepo:  refreshRepo,
		tokenRepo:    tokenRepo,
		notifier:     NewNotifier(tokenRepo, mailer, appBaseURL),
		secret:       secret,
		accessExpiry: accessExpirySeconds,
		refreshTTL:   refreshTTL,
	}
}

func (s *Service) Login(ctx context.Context, req dto.LoginRequest) (*dto.AuthResponse, error) {
	u, err := s.userRepo.GetByEmail(ctx, strings.ToLower(strings.TrimSpace(req.Email)))
	if errors.Is(err, repository.ErrNotFound) {
		return nil, service.ErrUnauthorized
	}
	if err != nil {
		return nil, err
	}
	if err := bcrypt.CompareHashAndPassword([]byte(u.Password), []byte(req.Password)); err != nil {
		return nil, service.ErrUnauthorized
	}
	if !u.Active {
		return nil, service.ErrUnauthorized
	}
	if !u.EmailVerified {
		return nil, service.ErrEmailNotVerified
	}
	return s.issueTokens(ctx, u)
}

func (s *Service) Refresh(ctx context.Context, raw string) (*dto.AuthResponse, error) {
	hash := jwt.HashToken(raw)
	rt, err := s.refreshRepo.GetByHash(ctx, hash)
	if errors.Is(err, repository.ErrNotFound) {
		return nil, service.ErrUnauthorized
	}
	if err != nil {
		return nil, err
	}
	if rt.Revoked || time.Now().After(rt.ExpiresAt) {
		return nil, service.ErrUnauthorized
	}
	if err := s.refreshRepo.Revoke(ctx, hash); err != nil {
		return nil, err
	}
	u, err := s.userRepo.GetByID(ctx, rt.UserID)
	if err != nil {
		return nil, err
	}
	if !u.Active {
		return nil, service.ErrUnauthorized
	}
	return s.issueTokens(ctx, u)
}

func (s *Service) Logout(ctx context.Context, raw string) error {
	return s.refreshRepo.Revoke(ctx, jwt.HashToken(raw))
}

func (s *Service) VerifyEmail(ctx context.Context, raw string) error {
	tok, err := s.tokenRepo.GetValid(ctx, jwt.HashToken(raw), model.TokenTypeEmailVerify)
	if err != nil {
		return service.ErrTokenInvalid
	}
	u, err := s.userRepo.GetByID(ctx, tok.UserID)
	if err != nil {
		return err
	}
	if u.EmailVerified {
		return service.ErrEmailAlreadyVerified
	}
	if err := s.userRepo.SetEmailVerified(ctx, u.ID, time.Now()); err != nil {
		return err
	}
	return s.tokenRepo.MarkUsed(ctx, tok.ID)
}

func (s *Service) ResendVerification(ctx context.Context, emailAddr string) error {
	u, err := s.userRepo.GetByEmail(ctx, strings.ToLower(strings.TrimSpace(emailAddr)))
	if errors.Is(err, repository.ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if u.EmailVerified {
		return nil
	}
	return s.notifier.SendVerification(ctx, u)
}

func (s *Service) ForgotPassword(ctx context.Context, emailAddr string) error {
	u, err := s.userRepo.GetByEmail(ctx, strings.ToLower(strings.TrimSpace(emailAddr)))
	if errors.Is(err, repository.ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	return s.notifier.SendPasswordReset(ctx, u)
}

func (s *Service) ResetPassword(ctx context.Context, raw, newPassword string) error {
	tok, err := s.tokenRepo.GetValid(ctx, jwt.HashToken(raw), model.TokenTypePasswordReset)
	if err != nil {
		return service.ErrTokenInvalid
	}
	hashed, err := bcrypt.GenerateFromPassword([]byte(newPassword), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	if err := s.userRepo.UpdatePassword(ctx, tok.UserID, string(hashed)); err != nil {
		return err
	}
	if err := s.tokenRepo.MarkUsed(ctx, tok.ID); err != nil {
		return err
	}
	return s.refreshRepo.RevokeAllForUser(ctx, tok.UserID)
}

func (s *Service) issueTokens(ctx context.Context, u *model.User) (*dto.AuthResponse, error) {
	access, err := jwt.Generate(u.ID, u.Email, s.secret, s.accessExpiry)
	if err != nil {
		return nil, err
	}
	raw, hash, err := jwt.GenerateRefreshToken()
	if err != nil {
		return nil, err
	}
	rt := &model.RefreshToken{UserID: u.ID, TokenHash: hash, ExpiresAt: time.Now().Add(s.refreshTTL)}
	if err := s.refreshRepo.Create(ctx, rt); err != nil {
		return nil, err
	}
	return &dto.AuthResponse{
		Token:        access,
		RefreshToken: raw,
		User:         dto.UserToResponse(u),
	}, nil
}

func (s *Service) SendVerificationEmail(ctx context.Context, u *model.User) error {
	return s.notifier.SendVerification(ctx, u)
}
EOF
}

write_40_internal_service_auth_notifier_go() {
cat > internal/service/auth/notifier.go <<'EOF'
package auth

import (
	"context"
	"fmt"
	"time"

	"__GO_MODULE__/internal/email"
	"__GO_MODULE__/internal/model"
	tokenrepo "__GO_MODULE__/internal/repository/token"
	"__GO_MODULE__/pkg/jwt"
)

const (
	verifyTTL = 24 * time.Hour
	resetTTL  = 1 * time.Hour
)

type Notifier struct {
	tokenRepo tokenrepo.Repository
	mailer    email.Sender
	appURL    string
}

func NewNotifier(tr tokenrepo.Repository, m email.Sender, appURL string) *Notifier {
	return &Notifier{tokenRepo: tr, mailer: m, appURL: appURL}
}

func (n *Notifier) SendVerification(ctx context.Context, u *model.User) error {
	raw, hash, err := jwt.GenerateRefreshToken()
	if err != nil {
		return err
	}
	_ = n.tokenRepo.InvalidateAllForUser(ctx, u.ID, model.TokenTypeEmailVerify)
	tok := &model.OneTimeToken{
		UserID:    u.ID,
		TokenHash: hash,
		Type:      model.TokenTypeEmailVerify,
		ExpiresAt: time.Now().Add(verifyTTL),
	}
	if err := n.tokenRepo.Create(ctx, tok); err != nil {
		return err
	}
	link := fmt.Sprintf("%s/verify-email?token=%s", n.appURL, raw)
	return n.mailer.Send(ctx, email.Message{
		To:      u.Email,
		Subject: "Verify your email",
		Body:    fmt.Sprintf("Hi %s,\n\nVerify your email by visiting:\n%s\n\nLink expires in 24h.", u.Name, link),
	})
}

func (n *Notifier) SendPasswordReset(ctx context.Context, u *model.User) error {
	raw, hash, err := jwt.GenerateRefreshToken()
	if err != nil {
		return err
	}
	_ = n.tokenRepo.InvalidateAllForUser(ctx, u.ID, model.TokenTypePasswordReset)
	tok := &model.OneTimeToken{
		UserID:    u.ID,
		TokenHash: hash,
		Type:      model.TokenTypePasswordReset,
		ExpiresAt: time.Now().Add(resetTTL),
	}
	if err := n.tokenRepo.Create(ctx, tok); err != nil {
		return err
	}
	link := fmt.Sprintf("%s/reset-password?token=%s", n.appURL, raw)
	return n.mailer.Send(ctx, email.Message{
		To:      u.Email,
		Subject: "Reset your password",
		Body:    fmt.Sprintf("Hi %s,\n\nReset your password by visiting:\n%s\n\nLink expires in 1h.", u.Name, link),
	})
}
EOF
}

write_41_internal_service_user_user_go() {
cat > internal/service/user/user.go <<'EOF'
package user

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"

	"golang.org/x/crypto/bcrypt"
	"golang.org/x/sync/singleflight"

	"__GO_MODULE__/internal/cache"
	"__GO_MODULE__/internal/dto"
	"__GO_MODULE__/internal/model"
	"__GO_MODULE__/internal/repository"
	userrepo "__GO_MODULE__/internal/repository/user"
	"__GO_MODULE__/internal/service"
	authsvc "__GO_MODULE__/internal/service/auth"
	rbacsvc "__GO_MODULE__/internal/service/rbac"
)

type Service struct {
	repo      userrepo.Repository
	auth      *authsvc.Service
	rbac      *rbacsvc.Service
	userCache *cache.UserCache
	group     singleflight.Group
}

func New(repo userrepo.Repository, a *authsvc.Service, r *rbacsvc.Service, uc *cache.UserCache) *Service {
	return &Service{repo: repo, auth: a, rbac: r, userCache: uc}
}

func (s *Service) Create(ctx context.Context, req dto.CreateUserRequest) (*model.User, error) {
	email := strings.ToLower(strings.TrimSpace(req.Email))
	if _, err := s.repo.GetByEmail(ctx, email); err == nil {
		return nil, service.ErrEmailTaken
	} else if !errors.Is(err, repository.ErrNotFound) {
		return nil, err
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		return nil, fmt.Errorf("hash password: %w", err)
	}

	u := &model.User{
		Name:          strings.TrimSpace(req.Name),
		Email:         email,
		Password:      string(hash),
		Active:        true,
		EmailVerified: false,
	}
	if err := s.repo.Create(ctx, u); err != nil {
		return nil, err
	}

	if err := s.rbac.AssignRole(ctx, u.ID, "user"); err != nil {
		slog.Warn("assign default role", "err", err, "user_id", u.ID)
	}
	if err := s.auth.SendVerificationEmail(ctx, u); err != nil {
		slog.Warn("send verification email", "err", err, "user_id", u.ID)
	}
	return u, nil
}

func (s *Service) Get(ctx context.Context, id uint) (*model.User, error) {
	return cache.GetOrLoad(
		ctx,
		&s.group,
		fmt.Sprintf("user:%d", id),
		func(ctx context.Context) (*model.User, bool) {
			return s.userCache.Get(ctx, id)
		},
		func(ctx context.Context, u *model.User) {
			s.userCache.Set(ctx, u)
		},
		func(ctx context.Context) (*model.User, error) {
			return s.repo.GetByID(ctx, id)
		},
	)
}

func (s *Service) List(ctx context.Context, page, limit int) ([]model.User, int64, error) {
	if page < 1 {
		page = 1
	}
	if limit < 1 || limit > 100 {
		limit = 20
	}
	return s.repo.List(ctx, limit, (page-1)*limit)
}

func (s *Service) Update(ctx context.Context, id uint, req dto.UpdateUserRequest) (*model.User, error) {
	u, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}
	if req.Name != nil {
		u.Name = strings.TrimSpace(*req.Name)
	}
	if req.Email != nil {
		newEmail := strings.ToLower(strings.TrimSpace(*req.Email))
		if newEmail != u.Email {
			if existing, err := s.repo.GetByEmail(ctx, newEmail); err == nil && existing.ID != u.ID {
				return nil, service.ErrEmailTaken
			}
			u.Email = newEmail
		}
	}
	if err := s.repo.Update(ctx, u); err != nil {
		return nil, err
	}
	s.userCache.Invalidate(ctx, id)
	return u, nil
}

func (s *Service) Delete(ctx context.Context, id uint) error {
	if err := s.repo.Delete(ctx, id); err != nil {
		return err
	}
	s.userCache.Invalidate(ctx, id)
	return nil
}

EOF
}

write_42_internal_service_rbac_rbac_go() {
cat > internal/service/rbac/rbac.go <<'EOF'
package rbac

import (
	"context"
	"fmt"

	"golang.org/x/sync/singleflight"

	"__GO_MODULE__/internal/cache"
	"__GO_MODULE__/internal/model"
	rbacrepo "__GO_MODULE__/internal/repository/rbac"
)

type Service struct {
	repo  rbacrepo.Repository
	cache *cache.RBACCache
	lock  *cache.Lock
	group singleflight.Group
}

func New(repo rbacrepo.Repository, c *cache.RBACCache, l *cache.Lock) *Service {
	return &Service{repo: repo, cache: c, lock: l}
}

func (s *Service) Permissions(ctx context.Context, userID uint) ([]string, error) {
	return cache.GetOrLoad(
		ctx,
		&s.group,
		fmt.Sprintf("perms:%d", userID),
		func(ctx context.Context) ([]string, bool) {
			return s.cache.Get(ctx, userID)
		},
		func(ctx context.Context, perms []string) {
			s.cache.Set(ctx, userID, perms)
		},
		func(ctx context.Context) ([]string, error) {
			return s.repo.GetUserPermissions(ctx, userID)
		},
	)
}

func (s *Service) HasPermission(ctx context.Context, userID uint, permission string) (bool, error) {
	perms, err := s.Permissions(ctx, userID)
	if err != nil {
		return false, err
	}
	for _, p := range perms {
		if p == permission {
			return true, nil
		}
	}
	return false, nil
}

func (s *Service) HasAnyPermission(ctx context.Context, userID uint, wants ...string) (bool, error) {
	perms, err := s.Permissions(ctx, userID)
	if err != nil {
		return false, err
	}
	set := make(map[string]struct{}, len(perms))
	for _, p := range perms {
		set[p] = struct{}{}
	}
	for _, w := range wants {
		if _, ok := set[w]; ok {
			return true, nil
		}
	}
	return false, nil
}

func (s *Service) List(ctx context.Context) ([]model.Role, error) {
	return s.repo.ListRoles(ctx)
}

func (s *Service) AssignRole(ctx context.Context, userID uint, roleName string) error {
	if err := s.repo.AssignRoleByName(ctx, userID, roleName); err != nil {
		return err
	}
	s.cache.Invalidate(ctx, userID)
	return nil
}

func (s *Service) RevokeRole(ctx context.Context, userID uint, roleName string) error {
	if err := s.repo.RevokeRoleByName(ctx, userID, roleName); err != nil {
		return err
	}
	s.cache.Invalidate(ctx, userID)
	return nil
}

func (s *Service) SetRolePermissions(ctx context.Context, roleName string, perms []string) error {
	userIDs, err := s.repo.SetRolePermissionsByName(ctx, roleName, perms)
	if err != nil {
		return err
	}
	s.cache.InvalidateUsers(ctx, userIDs)
	return nil
}

func (s *Service) CacheInvalidate(ctx context.Context, userID uint) error {
	s.cache.Invalidate(ctx, userID)
	return nil
}
EOF
}

write_43_internal_service_admin_admin_go() {
cat > internal/service/admin/admin.go <<'EOF'
package admin

import (
	"context"
	"time"

	"__GO_MODULE__/internal/dto"
	"__GO_MODULE__/internal/model"
	"__GO_MODULE__/internal/repository"
	rbacrepo "__GO_MODULE__/internal/repository/rbac"
	userrepo "__GO_MODULE__/internal/repository/user"
	"__GO_MODULE__/internal/service"
	rbacsvc "__GO_MODULE__/internal/service/rbac"
)

type Service struct {
	userRepo userrepo.Repository
	rbacRepo rbacrepo.Repository
	rbacSvc  *rbacsvc.Service
}

func New(u userrepo.Repository, r rbacrepo.Repository, rs *rbacsvc.Service) *Service {
	return &Service{userRepo: u, rbacRepo: r, rbacSvc: rs}
}

func (s *Service) ListUsers(ctx context.Context, q dto.ListAdminUsersQuery) ([]dto.AdminUserResponse, int64, error) {
	page, limit := q.Page, q.Limit
	if page < 1 {
		page = 1
	}
	if limit < 1 || limit > 100 {
		limit = 20
	}

	users, total, err := s.userRepo.ListFiltered(ctx, userrepo.Filter{
		Search: q.Search, RoleName: q.RoleName, Active: q.Active,
		Limit: limit, Offset: (page - 1) * limit,
	})
	if err != nil {
		return nil, 0, err
	}
	out := make([]dto.AdminUserResponse, 0, len(users))
	for i := range users {
		u := &users[i]
		roles, _ := s.rbacRepo.GetUserRoleNames(ctx, u.ID)
		perms, _ := s.rbacSvc.Permissions(ctx, u.ID)
		out = append(out, dto.AdminUserResponse{
			ID: u.ID, Name: u.Name, Email: u.Email,
			Active: u.Active, EmailVerified: u.EmailVerified,
			Roles: roles, Permissions: perms,
			CreatedAt: u.CreatedAt.Format(time.RFC3339),
		})
	}
	return out, total, nil
}

func (s *Service) GetUser(ctx context.Context, id uint) (*dto.AdminUserResponse, error) {
	u, err := s.userRepo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}
	roles, _ := s.rbacRepo.GetUserRoleNames(ctx, u.ID)
	perms, _ := s.rbacSvc.Permissions(ctx, u.ID)
	return &dto.AdminUserResponse{
		ID: u.ID, Name: u.Name, Email: u.Email,
		Active: u.Active, EmailVerified: u.EmailVerified,
		Roles: roles, Permissions: perms,
		CreatedAt: u.CreatedAt.Format(time.RFC3339),
	}, nil
}

func (s *Service) SetUserActive(ctx context.Context, id uint, active bool) error {
	if err := s.userRepo.SetActive(ctx, id, active); err != nil {
		return err
	}
	return s.rbacSvc.CacheInvalidate(ctx, id)
}

func (s *Service) AssignRole(ctx context.Context, userID uint, roleName string) error {
	return s.rbacSvc.AssignRole(ctx, userID, roleName)
}

func (s *Service) RevokeRole(ctx context.Context, actorID, userID uint, roleName string) error {
	if actorID == userID && roleName == "admin" {
		return service.ErrForbidden
	}
	return s.rbacSvc.RevokeRole(ctx, userID, roleName)
}

func (s *Service) ListRoles(ctx context.Context) ([]dto.RoleResponse, error) {
	roles, err := s.rbacRepo.ListRoles(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]dto.RoleResponse, 0, len(roles))
	for _, r := range roles {
		perms := make([]string, 0, len(r.Permissions))
		for _, p := range r.Permissions {
			perms = append(perms, p.Name)
		}
		out = append(out, dto.RoleResponse{ID: r.ID, Name: r.Name, Description: r.Description, Permissions: perms})
	}
	return out, nil
}

func (s *Service) CreateRole(ctx context.Context, req dto.CreateRoleRequest) (*dto.RoleResponse, error) {
	role := &model.Role{Name: req.Name, Description: req.Description}
	if err := s.rbacRepo.CreateRole(ctx, role); err != nil {
		return nil, err
	}
	if len(req.Permissions) > 0 {
		if err := s.rbacSvc.SetRolePermissions(ctx, role.Name, req.Permissions); err != nil {
			return nil, err
		}
	}
	return s.roleResponse(ctx, role.Name)
}

func (s *Service) SetRolePermissions(ctx context.Context, roleName string, perms []string) error {
	return s.rbacSvc.SetRolePermissions(ctx, roleName, perms)
}

func (s *Service) ListPermissions(ctx context.Context) ([]dto.PermissionResponse, error) {
	perms, err := s.rbacRepo.ListPermissions(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]dto.PermissionResponse, 0, len(perms))
	for _, p := range perms {
		out = append(out, dto.PermissionResponse{ID: p.ID, Name: p.Name, Description: p.Description})
	}
	return out, nil
}

func (s *Service) CreatePermission(ctx context.Context, req dto.CreatePermissionRequest) (*dto.PermissionResponse, error) {
	p := &model.Permission{Name: req.Name, Description: req.Description}
	if err := s.rbacRepo.CreatePermission(ctx, p); err != nil {
		return nil, err
	}
	return &dto.PermissionResponse{ID: p.ID, Name: p.Name, Description: p.Description}, nil
}

func (s *Service) roleResponse(ctx context.Context, name string) (*dto.RoleResponse, error) {
	roles, err := s.rbacRepo.ListRoles(ctx)
	if err != nil {
		return nil, err
	}
	for _, r := range roles {
		if r.Name == name {
			perms := make([]string, 0, len(r.Permissions))
			for _, p := range r.Permissions {
				perms = append(perms, p.Name)
			}
			return &dto.RoleResponse{ID: r.ID, Name: r.Name, Description: r.Description, Permissions: perms}, nil
		}
	}
	return nil, repository.ErrNotFound
}
EOF
}

write_44_internal_service_cleanup_cleanup_go() {
cat > internal/service/cleanup/cleanup.go <<'EOF'
package cleanup

import (
	"context"
	"log/slog"
	"time"

	refreshtokenrepo "__GO_MODULE__/internal/repository/refresh_token"
	tokenrepo "__GO_MODULE__/internal/repository/token"
)

type Service struct {
	tokenRepo   tokenrepo.Repository
	refreshRepo refreshtokenrepo.Repository
}

func New(t tokenrepo.Repository, r refreshtokenrepo.Repository) *Service {
	return &Service{tokenRepo: t, refreshRepo: r}
}

func (s *Service) Run(ctx context.Context, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := s.tokenRepo.DeleteExpired(ctx); err != nil {
				slog.Warn("cleanup tokens", "err", err)
			}
			if err := s.refreshRepo.DeleteExpired(ctx); err != nil {
				slog.Warn("cleanup refresh", "err", err)
			}
		}
	}
}
EOF
}

write_45_internal_middleware_auth_go() {
cat > internal/middleware/auth.go <<'EOF'
package middleware

import (
	"context"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"__GO_MODULE__/pkg/jwt"
)

type ctxKey string

const (
	UserIDKey ctxKey = "userID"
	EmailKey  ctxKey = "email"
)

func Auth(secret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		auth := c.GetHeader("Authorization")
		token, ok := strings.CutPrefix(auth, "Bearer ")
		if !ok || token == "" {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "missing or invalid token"})
			return
		}
		claims, err := jwt.Parse(token, secret)
		if err != nil {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid token"})
			return
		}
		ctx := context.WithValue(c.Request.Context(), UserIDKey, claims.UserID)
		ctx = context.WithValue(ctx, EmailKey, claims.Email)
		c.Request = c.Request.WithContext(ctx)
		c.Set(string(UserIDKey), claims.UserID)
		c.Set(string(EmailKey), claims.Email)
		c.Next()
	}
}

func GetUserID(c *gin.Context) (uint, bool) {
	v, ok := c.Get(string(UserIDKey))
	if !ok {
		return 0, false
	}
	id, ok := v.(uint)
	return id, ok
}

func GetEmail(c *gin.Context) string {
	v, _ := c.Get(string(EmailKey))
	s, _ := v.(string)
	return s
}
EOF
}

write_46_internal_middleware_rbac_go() {
cat > internal/middleware/rbac.go <<'EOF'
package middleware

import (
	"net/http"

	"github.com/gin-gonic/gin"

	rbacsvc "__GO_MODULE__/internal/service/rbac"
)

func RequirePermission(rbac *rbacsvc.Service, permission string) gin.HandlerFunc {
	return func(c *gin.Context) {
		uid, ok := GetUserID(c)
		if !ok {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
			return
		}
		has, err := rbac.HasPermission(c.Request.Context(), uid, permission)
		if err != nil {
			c.AbortWithStatusJSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
			return
		}
		if !has {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "forbidden"})
			return
		}
		c.Next()
	}
}
EOF
}

write_47_internal_middleware_logging_go() {
cat > internal/middleware/logging.go <<'EOF'
package middleware

import (
	"log/slog"
	"time"

	"github.com/gin-gonic/gin"
)

func Logging() gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()
		slog.Info("request",
			"method", c.Request.Method,
			"path", c.Request.URL.Path,
			"status", c.Writer.Status(),
			"duration_ms", time.Since(start).Milliseconds(),
			"client_ip", c.ClientIP(),
		)
	}
}
EOF
}

write_48_internal_middleware_recovery_go() {
cat > internal/middleware/recovery.go <<'EOF'
package middleware

import (
	"log/slog"
	"net/http"

	"github.com/gin-gonic/gin"
)

func Recovery() gin.HandlerFunc {
	return func(c *gin.Context) {
		defer func() {
			if rec := recover(); rec != nil {
				slog.Error("panic recovered", "err", rec, "path", c.Request.URL.Path)
				c.AbortWithStatusJSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
			}
		}()
		c.Next()
	}
}
EOF
}

write_49_internal_middleware_metrics_go() {
cat > internal/middleware/metrics.go <<'EOF'
package middleware

import (
	"time"

	"github.com/gin-gonic/gin"

	"__GO_MODULE__/internal/metrics"
)

func Metrics() gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()
		route := c.FullPath()
		if route == "" {
			route = "unknown"
		}
		metrics.HTTPRequestsTotal.
			WithLabelValues(c.Request.Method, route, statusClass(c.Writer.Status())).Inc()
		metrics.HTTPRequestDuration.
			WithLabelValues(c.Request.Method, route).Observe(time.Since(start).Seconds())
	}
}

func statusClass(code int) string {
	switch {
	case code >= 500:
		return "5xx"
	case code >= 400:
		return "4xx"
	case code >= 300:
		return "3xx"
	case code >= 200:
		return "2xx"
	default:
		return "1xx"
	}
}
EOF
}

write_50_internal_middleware_ratelimit_go() {
cat > internal/middleware/ratelimit.go <<'EOF'
package middleware

import (
	"fmt"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
)

func RateLimit(rdb *redis.Client, prefix string, limit int, window time.Duration) gin.HandlerFunc {
	return func(c *gin.Context) {
		key := fmt.Sprintf("rl:%s:ip:%s", prefix, c.ClientIP())
		if prefix == "user" {
			if uid, ok := GetUserID(c); ok {
				key = fmt.Sprintf("rl:%s:u:%d", prefix, uid)
			}
		}
		ctx := c.Request.Context()
		pipe := rdb.Pipeline()
		incr := pipe.Incr(ctx, key)
		pipe.Expire(ctx, key, window)
		if _, err := pipe.Exec(ctx); err != nil {
			c.Next()
			return
		}
		if incr.Val() > int64(limit) {
			c.Header("Retry-After", fmt.Sprintf("%d", int(window.Seconds())))
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{"error": "rate limit exceeded"})
			return
		}
		c.Next()
	}
}
EOF
}

write_51_internal_middleware_security_go() {
cat > internal/middleware/security.go <<'EOF'
package middleware

import "github.com/gin-gonic/gin"

func SecurityHeaders() gin.HandlerFunc {
	return func(c *gin.Context) {
		h := c.Writer.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "strict-origin-when-cross-origin")
		h.Set("Permissions-Policy", "geolocation=(), microphone=(), camera=()")
		if c.Request.TLS != nil {
			h.Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
		}
		c.Next()
	}
}
EOF
}

write_52_internal_middleware_cors_go() {
cat > internal/middleware/cors.go <<'EOF'
package middleware

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

func CORS(origins []string) gin.HandlerFunc {
	allowed := map[string]bool{}
	for _, o := range origins {
		allowed[strings.TrimSpace(o)] = true
	}
	return func(c *gin.Context) {
		origin := c.GetHeader("Origin")
		if origin != "" && (allowed[origin] || allowed["*"]) {
			h := c.Writer.Header()
			if allowed["*"] {
				h.Set("Access-Control-Allow-Origin", "*")
			} else {
				h.Set("Access-Control-Allow-Origin", origin)
				h.Set("Vary", "Origin")
				h.Set("Access-Control-Allow-Credentials", "true")
			}
			h.Set("Access-Control-Allow-Methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS")
			h.Set("Access-Control-Allow-Headers", "Authorization,Content-Type,Accept")
			h.Set("Access-Control-Max-Age", "600")
		}
		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}
EOF
}

write_53_internal_middleware_bodylimit_go() {
cat > internal/middleware/bodylimit.go <<'EOF'
package middleware

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

func BodyLimit(maxBytes int64) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxBytes)
		c.Next()
	}
}
EOF
}

write_54_internal_handler_response_go() {
cat > internal/handler/response.go <<'EOF'
package handler

import (
	"errors"
	"log/slog"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/go-playground/validator/v10"

	"__GO_MODULE__/internal/repository"
	"__GO_MODULE__/internal/service"
)

var validate = validator.New()

type ErrorResponse struct {
	Error   string            `json:"error"`
	Details map[string]string `json:"details,omitempty"`
}

type PaginatedResponse struct {
	Data  any   `json:"data"`
	Total int64 `json:"total"`
	Page  int   `json:"page"`
	Limit int   `json:"limit"`
}

func respondError(c *gin.Context, status int, msg string) {
	c.JSON(status, ErrorResponse{Error: msg})
}

func respondValidationError(c *gin.Context, err error) {
	details := map[string]string{}
	var ve validator.ValidationErrors
	if errors.As(err, &ve) {
		for _, fe := range ve {
			details[fe.Field()] = validationMessage(fe)
		}
	}
	c.JSON(http.StatusBadRequest, ErrorResponse{Error: "validation failed", Details: details})
}

func validationMessage(fe validator.FieldError) string {
	switch fe.Tag() {
	case "required":
		return "is required"
	case "email":
		return "must be a valid email"
	case "min":
		return "must be at least " + fe.Param()
	case "max":
		return "must be at most " + fe.Param()
	default:
		return "invalid"
	}
}

func respondServiceError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, repository.ErrNotFound):
		respondError(c, http.StatusNotFound, "resource not found")
	case errors.Is(err, service.ErrInvalidInput):
		respondError(c, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrEmailTaken):
		respondError(c, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrUnauthorized):
		respondError(c, http.StatusUnauthorized, "invalid credentials")
	case errors.Is(err, service.ErrForbidden):
		respondError(c, http.StatusForbidden, "forbidden")
	case errors.Is(err, service.ErrEmailNotVerified):
		respondError(c, http.StatusForbidden, "email not verified")
	case errors.Is(err, service.ErrTokenInvalid):
		respondError(c, http.StatusBadRequest, "invalid or expired token")
	case errors.Is(err, service.ErrEmailAlreadyVerified):
		respondError(c, http.StatusConflict, "email already verified")
	default:
		slog.Error("unhandled error", "err", err)
		respondError(c, http.StatusInternalServerError, "internal server error")
	}
}
EOF
}

write_55_internal_handler_user_go() {
cat > internal/handler/user.go <<'EOF'
package handler

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"__GO_MODULE__/internal/dto"
	usersvc "__GO_MODULE__/internal/service/user"
)

type UserHandler struct{ svc *usersvc.Service }

func NewUserHandler(svc *usersvc.Service) *UserHandler { return &UserHandler{svc: svc} }

func (h *UserHandler) Register(r *gin.RouterGroup) {
	g := r.Group("/users")
	g.POST("", h.create)
	g.GET("", h.list)
	g.GET("/:id", h.get)
	g.PUT("/:id", h.update)
	g.DELETE("/:id", h.delete)
}

// @Summary Create user
// @Tags users
// @Router /users [post]
func (h *UserHandler) create(c *gin.Context) {
	var req dto.CreateUserRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		respondError(c, http.StatusBadRequest, "invalid JSON")
		return
	}
	if err := validate.Struct(req); err != nil {
		respondValidationError(c, err)
		return
	}
	u, err := h.svc.Create(c.Request.Context(), req)
	if err != nil {
		respondServiceError(c, err)
		return
	}
	c.JSON(http.StatusCreated, dto.UserToResponse(u))
}

// @Summary List users
// @Tags users
// @Router /users [get]
func (h *UserHandler) list(c *gin.Context) {
	var q dto.ListUsersQuery
	_ = c.ShouldBindQuery(&q)
	if q.Page == 0 {
		q.Page = 1
	}
	if q.Limit == 0 {
		q.Limit = 20
	}
	users, total, err := h.svc.List(c.Request.Context(), q.Page, q.Limit)
	if err != nil {
		respondServiceError(c, err)
		return
	}
	out := make([]*dto.UserResponse, 0, len(users))
	for i := range users {
		out = append(out, dto.UserToResponse(&users[i]))
	}
	c.JSON(http.StatusOK, PaginatedResponse{Data: out, Total: total, Page: q.Page, Limit: q.Limit})
}

// @Summary Get user
// @Tags users
// @Router /users/{id} [get]
func (h *UserHandler) get(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		respondError(c, http.StatusBadRequest, "invalid id")
		return
	}
	u, err := h.svc.Get(c.Request.Context(), uint(id))
	if err != nil {
		respondServiceError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.UserToResponse(u))
}

// @Summary Update user
// @Tags users
// @Router /users/{id} [put]
func (h *UserHandler) update(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		respondError(c, http.StatusBadRequest, "invalid id")
		return
	}
	var req dto.UpdateUserRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		respondError(c, http.StatusBadRequest, "invalid JSON")
		return
	}
	if err := validate.Struct(req); err != nil {
		respondValidationError(c, err)
		return
	}
	u, err := h.svc.Update(c.Request.Context(), uint(id), req)
	if err != nil {
		respondServiceError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.UserToResponse(u))
}

// @Summary Delete user
// @Tags users
// @Router /users/{id} [delete]
func (h *UserHandler) delete(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		respondError(c, http.StatusBadRequest, "invalid id")
		return
	}
	if err := h.svc.Delete(c.Request.Context(), uint(id)); err != nil {
		respondServiceError(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}
EOF
}

write_56_internal_handler_auth_go() {
cat > internal/handler/auth.go <<'EOF'
package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"__GO_MODULE__/internal/dto"
	"__GO_MODULE__/internal/middleware"
	authsvc "__GO_MODULE__/internal/service/auth"
	rbacsvc "__GO_MODULE__/internal/service/rbac"
	usersvc "__GO_MODULE__/internal/service/user"
)

type AuthHandler struct {
	svc     *authsvc.Service
	userSvc *usersvc.Service
	rbacSvc *rbacsvc.Service
}

func NewAuthHandler(svc *authsvc.Service, us *usersvc.Service, rs *rbacsvc.Service) *AuthHandler {
	return &AuthHandler{svc: svc, userSvc: us, rbacSvc: rs}
}

func (h *AuthHandler) Register(r *gin.RouterGroup) {
	g := r.Group("/auth")
	g.POST("/login", h.login)
	g.POST("/refresh", h.refresh)
	g.POST("/logout", h.logout)
	g.POST("/verify-email", h.verifyEmail)
	g.POST("/resend-verification", h.resendVerification)
	g.POST("/forgot-password", h.forgotPassword)
	g.POST("/reset-password", h.resetPassword)
}

// @Summary Login
// @Tags auth
// @Router /auth/login [post]
func (h *AuthHandler) login(c *gin.Context) {
	var req dto.LoginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		respondError(c, http.StatusBadRequest, "invalid JSON")
		return
	}
	if err := validate.Struct(req); err != nil {
		respondValidationError(c, err)
		return
	}
	res, err := h.svc.Login(c.Request.Context(), req)
	if err != nil {
		respondServiceError(c, err)
		return
	}
	c.JSON(http.StatusOK, res)
}

// @Summary Refresh access token
// @Tags auth
// @Router /auth/refresh [post]
func (h *AuthHandler) refresh(c *gin.Context) {
	var req dto.RefreshRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		respondError(c, http.StatusBadRequest, "invalid JSON")
		return
	}
	if err := validate.Struct(req); err != nil {
		respondValidationError(c, err)
		return
	}
	res, err := h.svc.Refresh(c.Request.Context(), req.RefreshToken)
	if err != nil {
		respondServiceError(c, err)
		return
	}
	c.JSON(http.StatusOK, res)
}

// @Summary Logout
// @Tags auth
// @Router /auth/logout [post]
func (h *AuthHandler) logout(c *gin.Context) {
	var req dto.RefreshRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		respondError(c, http.StatusBadRequest, "invalid JSON")
		return
	}
	if err := h.svc.Logout(c.Request.Context(), req.RefreshToken); err != nil {
		respondServiceError(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}

// @Summary Verify email
// @Tags auth
// @Router /auth/verify-email [post]
func (h *AuthHandler) verifyEmail(c *gin.Context) {
	var req dto.VerifyEmailRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		respondError(c, http.StatusBadRequest, "invalid JSON")
		return
	}
	if err := validate.Struct(req); err != nil {
		respondValidationError(c, err)
		return
	}
	if err := h.svc.VerifyEmail(c.Request.Context(), req.Token); err != nil {
		respondServiceError(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}

// @Summary Resend verification email
// @Tags auth
// @Router /auth/resend-verification [post]
func (h *AuthHandler) resendVerification(c *gin.Context) {
	var req dto.ResendVerificationRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		respondError(c, http.StatusBadRequest, "invalid JSON")
		return
	}
	if err := validate.Struct(req); err != nil {
		respondValidationError(c, err)
		return
	}
	_ = h.svc.ResendVerification(c.Request.Context(), req.Email)
	c.Status(http.StatusNoContent)
}

// @Summary Request password reset
// @Tags auth
// @Router /auth/forgot-password [post]
func (h *AuthHandler) forgotPassword(c *gin.Context) {
	var req dto.ForgotPasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		respondError(c, http.StatusBadRequest, "invalid JSON")
		return
	}
	if err := validate.Struct(req); err != nil {
		respondValidationError(c, err)
		return
	}
	_ = h.svc.ForgotPassword(c.Request.Context(), req.Email)
	c.Status(http.StatusNoContent)
}

// @Summary Reset password
// @Tags auth
// @Router /auth/reset-password [post]
func (h *AuthHandler) resetPassword(c *gin.Context) {
	var req dto.ResetPasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		respondError(c, http.StatusBadRequest, "invalid JSON")
		return
	}
	if err := validate.Struct(req); err != nil {
		respondValidationError(c, err)
		return
	}
	if err := h.svc.ResetPassword(c.Request.Context(), req.Token, req.NewPassword); err != nil {
		respondServiceError(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}

// @Summary Get current user
// @Tags auth
// @Security BearerAuth
// @Router /auth/me [get]
func (h *AuthHandler) Me(c *gin.Context) {
	uid, ok := middleware.GetUserID(c)
	if !ok {
		respondError(c, http.StatusUnauthorized, "unauthorized")
		return
	}
	u, err := h.userSvc.Get(c.Request.Context(), uid)
	if err != nil {
		respondServiceError(c, err)
		return
	}
	perms, _ := h.rbacSvc.Permissions(c.Request.Context(), uid)
	resp := dto.UserToResponse(u)
	resp.Permissions = perms
	c.JSON(http.StatusOK, resp)
}
EOF
}

write_57_internal_handler_admin_go() {
cat > internal/handler/admin.go <<'EOF'
package handler

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"__GO_MODULE__/internal/dto"
	"__GO_MODULE__/internal/middleware"
	adminsvc "__GO_MODULE__/internal/service/admin"
)

type AdminHandler struct{ svc *adminsvc.Service }

func NewAdminHandler(svc *adminsvc.Service) *AdminHandler { return &AdminHandler{svc: svc} }

func (h *AdminHandler) Register(r *gin.RouterGroup) {
	g := r.Group("/admin")
	g.GET("/users", h.listUsers)
	g.GET("/users/:id", h.getUser)
	g.PATCH("/users/:id/active", h.setUserActive)
	g.POST("/users/:id/roles", h.assignRole)
	g.DELETE("/users/:id/roles/:role", h.revokeRole)

	g.GET("/roles", h.listRoles)
	g.POST("/roles", h.createRole)
	g.PUT("/roles/:name/permissions", h.setRolePermissions)

	g.GET("/permissions", h.listPermissions)
	g.POST("/permissions", h.createPermission)
}

// @Summary List users for administration
// @Tags admin
// @Security BearerAuth
// @Router /admin/users [get]
func (h *AdminHandler) listUsers(c *gin.Context) {
	var q dto.ListAdminUsersQuery
	_ = c.ShouldBindQuery(&q)
	if q.Page == 0 {
		q.Page = 1
	}
	if q.Limit == 0 {
		q.Limit = 20
	}
	users, total, err := h.svc.ListUsers(c.Request.Context(), q)
	if err != nil {
		respondServiceError(c, err)
		return
	}
	c.JSON(http.StatusOK, PaginatedResponse{Data: users, Total: total, Page: q.Page, Limit: q.Limit})
}

// @Summary Get user for administration
// @Tags admin
// @Security BearerAuth
// @Router /admin/users/{id} [get]
func (h *AdminHandler) getUser(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		respondError(c, http.StatusBadRequest, "invalid id")
		return
	}
	u, err := h.svc.GetUser(c.Request.Context(), uint(id))
	if err != nil {
		respondServiceError(c, err)
		return
	}
	c.JSON(http.StatusOK, u)
}

// @Summary Set user active status
// @Tags admin
// @Security BearerAuth
// @Router /admin/users/{id}/active [patch]
func (h *AdminHandler) setUserActive(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		respondError(c, http.StatusBadRequest, "invalid id")
		return
	}
	var req dto.SetActiveRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		respondError(c, http.StatusBadRequest, "invalid JSON")
		return
	}
	if err := h.svc.SetUserActive(c.Request.Context(), uint(id), req.Active); err != nil {
		respondServiceError(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}

// @Summary Assign role to user
// @Tags admin
// @Security BearerAuth
// @Router /admin/users/{id}/roles [post]
func (h *AdminHandler) assignRole(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		respondError(c, http.StatusBadRequest, "invalid id")
		return
	}
	var req dto.AssignRoleRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		respondError(c, http.StatusBadRequest, "invalid JSON")
		return
	}
	if err := validate.Struct(req); err != nil {
		respondValidationError(c, err)
		return
	}
	if err := h.svc.AssignRole(c.Request.Context(), uint(id), req.RoleName); err != nil {
		respondServiceError(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}

// @Summary Revoke role from user
// @Tags admin
// @Security BearerAuth
// @Router /admin/users/{id}/roles/{role} [delete]
func (h *AdminHandler) revokeRole(c *gin.Context) {
	actorID, _ := middleware.GetUserID(c)
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		respondError(c, http.StatusBadRequest, "invalid id")
		return
	}
	roleName := c.Param("role")
	if err := h.svc.RevokeRole(c.Request.Context(), actorID, uint(id), roleName); err != nil {
		respondServiceError(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}

// @Summary List roles
// @Tags admin
// @Security BearerAuth
// @Router /admin/roles [get]
func (h *AdminHandler) listRoles(c *gin.Context) {
	roles, err := h.svc.ListRoles(c.Request.Context())
	if err != nil {
		respondServiceError(c, err)
		return
	}
	c.JSON(http.StatusOK, roles)
}

// @Summary Create role
// @Tags admin
// @Security BearerAuth
// @Router /admin/roles [post]
func (h *AdminHandler) createRole(c *gin.Context) {
	var req dto.CreateRoleRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		respondError(c, http.StatusBadRequest, "invalid JSON")
		return
	}
	if err := validate.Struct(req); err != nil {
		respondValidationError(c, err)
		return
	}
	role, err := h.svc.CreateRole(c.Request.Context(), req)
	if err != nil {
		respondServiceError(c, err)
		return
	}
	c.JSON(http.StatusCreated, role)
}

// @Summary Set role permissions
// @Tags admin
// @Security BearerAuth
// @Router /admin/roles/{name}/permissions [put]
func (h *AdminHandler) setRolePermissions(c *gin.Context) {
	roleName := c.Param("name")
	var req dto.SetRolePermissionsRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		respondError(c, http.StatusBadRequest, "invalid JSON")
		return
	}
	if err := validate.Struct(req); err != nil {
		respondValidationError(c, err)
		return
	}
	if err := h.svc.SetRolePermissions(c.Request.Context(), roleName, req.Permissions); err != nil {
		respondServiceError(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}

// @Summary List permissions
// @Tags admin
// @Security BearerAuth
// @Router /admin/permissions [get]
func (h *AdminHandler) listPermissions(c *gin.Context) {
	perms, err := h.svc.ListPermissions(c.Request.Context())
	if err != nil {
		respondServiceError(c, err)
		return
	}
	c.JSON(http.StatusOK, perms)
}

// @Summary Create permission
// @Tags admin
// @Security BearerAuth
// @Router /admin/permissions [post]
func (h *AdminHandler) createPermission(c *gin.Context) {
	var req dto.CreatePermissionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		respondError(c, http.StatusBadRequest, "invalid JSON")
		return
	}
	if err := validate.Struct(req); err != nil {
		respondValidationError(c, err)
		return
	}
	p, err := h.svc.CreatePermission(c.Request.Context(), req)
	if err != nil {
		respondServiceError(c, err)
		return
	}
	c.JSON(http.StatusCreated, p)
}
EOF
}

write_58_internal_handler_health_go() {
cat > internal/handler/health.go <<'EOF'
package handler

import (
	"context"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
	"gorm.io/gorm"
)

type HealthHandler struct {
	db  *gorm.DB
	rdb *redis.Client
}

func NewHealthHandler(db *gorm.DB, rdb *redis.Client) *HealthHandler {
	return &HealthHandler{db: db, rdb: rdb}
}

func (h *HealthHandler) Register(r *gin.Engine) {
	r.GET("/health", h.health)
	r.GET("/ready", h.ready)
}

func (h *HealthHandler) health(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *HealthHandler) ready(c *gin.Context) {
	ctx, cancel := context.WithTimeout(c.Request.Context(), 2*time.Second)
	defer cancel()

	resp := gin.H{"status": "ok", "checks": gin.H{}}
	checks := resp["checks"].(gin.H)
	healthy := true

	sqlDB, err := h.db.DB()
	if err != nil || sqlDB.PingContext(ctx) != nil {
		checks["postgres"] = "fail"
		healthy = false
	} else {
		checks["postgres"] = "ok"
	}

	if err := h.rdb.Ping(ctx).Err(); err != nil {
		checks["redis"] = "fail (degraded)"
	} else {
		checks["redis"] = "ok"
	}

	if !healthy {
		resp["status"] = "unhealthy"
		c.JSON(http.StatusServiceUnavailable, resp)
		return
	}
	c.JSON(http.StatusOK, resp)
}
EOF
}

write_59_internal_handler_router_go() {
cat > internal/handler/router.go <<'EOF'
package handler

import (
	"time"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/redis/go-redis/v9"
	swaggerFiles "github.com/swaggo/files"
	ginSwagger "github.com/swaggo/gin-swagger"

	"__GO_MODULE__/internal/middleware"
	"__GO_MODULE__/internal/rbac"
	adminsvc "__GO_MODULE__/internal/service/admin"
	authsvc "__GO_MODULE__/internal/service/auth"
	rbacsvc "__GO_MODULE__/internal/service/rbac"
	usersvc "__GO_MODULE__/internal/service/user"
)

type Deps struct {
	UserSvc        *usersvc.Service
	AuthSvc        *authsvc.Service
	RBACSvc        *rbacsvc.Service
	AdminSvc       *adminsvc.Service
	Redis          *redis.Client
	Secret         string
	IsProd         bool
	AllowedOrigins []string
	HealthHandler  *HealthHandler
}

func NewRouter(d Deps) *gin.Engine {
	if d.IsProd {
		gin.SetMode(gin.ReleaseMode)
	}

	r := gin.New()
	r.Use(middleware.Recovery())
	r.Use(middleware.Logging())
	r.Use(middleware.Metrics())
	r.Use(middleware.SecurityHeaders())
	r.Use(middleware.CORS(d.AllowedOrigins))
	r.Use(middleware.BodyLimit(1 << 20))
	r.Use(middleware.RateLimit(d.Redis, "global", 300, time.Minute))

	if d.HealthHandler != nil {
		d.HealthHandler.Register(r)
	}

	r.GET("/metrics", gin.WrapH(promhttp.Handler()))
	r.GET("/swagger/*any", ginSwagger.WrapHandler(swaggerFiles.Handler))

	authMiddleware := middleware.Auth(d.Secret)

	v1 := r.Group("/api/v1")

	authGroup := v1.Group("/auth")
	authGroup.Use(middleware.RateLimit(d.Redis, "auth", 10, time.Minute))
	authHandler := NewAuthHandler(d.AuthSvc, d.UserSvc, d.RBACSvc)
	authHandler.Register(authGroup)

	v1.GET("/auth/me", authMiddleware, authHandler.Me)

	NewUserHandler(d.UserSvc).Register(v1)

	adminGroup := v1.Group("/admin")
	adminGroup.Use(authMiddleware, middleware.RequirePermission(d.RBACSvc, rbac.PermRolesManage))
	NewAdminHandler(d.AdminSvc).Register(adminGroup)

	return r
}
EOF
}

write_60_cmd_atlas_loader_main_go() {
cat > cmd/atlas-loader/main.go <<'EOF'
package main

import (
	"fmt"
	"io"
	"os"

	"ariga.io/atlas-provider-gorm/gormschema"

	"__GO_MODULE__/internal/model"
)

func main() {
	stmts, err := gormschema.New("postgres").Load(
		&model.User{},
		&model.RefreshToken{},
		&model.OneTimeToken{},
		&model.Role{},
		&model.Permission{},
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "load schema: %v\n", err)
		os.Exit(1)
	}
	io.WriteString(os.Stdout, stmts)
}
EOF
}

write_61_cmd_api_main_go() {
cat > cmd/api/main.go <<'EOF'
// @title           Starter API
// @version         1.0
// @description     Gin + GORM REST API starter.
// @host            localhost:8080
// @BasePath        /api/v1
// @securityDefinitions.apikey BearerAuth
// @in              header
// @name            Authorization
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "__GO_MODULE__/docs"
	"__GO_MODULE__/internal/cache"
	"__GO_MODULE__/internal/config"
	"__GO_MODULE__/internal/database"
	"__GO_MODULE__/internal/email"
	"__GO_MODULE__/internal/handler"
	refreshtokenrepo "__GO_MODULE__/internal/repository/refresh_token"
	rbacrepo "__GO_MODULE__/internal/repository/rbac"
	tokenrepo "__GO_MODULE__/internal/repository/token"
	userrepo "__GO_MODULE__/internal/repository/user"
	adminsvc "__GO_MODULE__/internal/service/admin"
	authsvc "__GO_MODULE__/internal/service/auth"
	cleanupsvc "__GO_MODULE__/internal/service/cleanup"
	rbacsvc "__GO_MODULE__/internal/service/rbac"
	usersvc "__GO_MODULE__/internal/service/user"
)

func main() {
	if err := run(); err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run() error {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))

	cfg, err := config.Load()
	if err != nil {
		return err
	}

	db, err := database.New(cfg.DatabaseURL, cfg.IsProduction())
	if err != nil {
		return err
	}
	if err := database.AutoMigrate(db); err != nil {
		return err
	}
	if err := database.SeedRBAC(db); err != nil {
		return err
	}

	rdb, err := cache.NewRedis(cfg.RedisURL)
	if err != nil {
		return err
	}

	var mailer email.Sender
	if cfg.IsProduction() && cfg.SMTPHost != "" {
		mailer = email.NewSMTPSender(cfg.SMTPHost, cfg.SMTPPort, cfg.SMTPUser, cfg.SMTPPass, cfg.SMTPFrom)
	} else {
		mailer = email.NewConsoleSender()
	}

	userRepo := userrepo.New(db)
	refreshRepo := refreshtokenrepo.New(db)
	tokenRepo := tokenrepo.New(db)
	rbacRepo := rbacrepo.New(db)

	rbacCache := cache.NewRBACCache(rdb)
	userCache := cache.NewUserCache(rdb)
	lock := cache.NewLock(rdb)

	rbacSvc := rbacsvc.New(rbacRepo, rbacCache, lock)
	authSvc := authsvc.New(userRepo, refreshRepo, tokenRepo, mailer,
		cfg.JWTSecret, int64(cfg.JWTExpiry.Seconds()), cfg.RefreshTTL, cfg.AppBaseURL)
	userSvc := usersvc.New(userRepo, authSvc, rbacSvc, userCache)
	adminSvc := adminsvc.New(userRepo, rbacRepo, rbacSvc)
	cleanupSvc := cleanupsvc.New(tokenRepo, refreshRepo)

	rootCtx, rootCancel := context.WithCancel(context.Background())
	defer rootCancel()
	go cleanupSvc.Run(rootCtx, time.Hour)

	if cfg.BootstrapAdmin != "" {
		if u, err := userRepo.GetByEmail(rootCtx, cfg.BootstrapAdmin); err == nil {
			_ = rbacSvc.AssignRole(rootCtx, u.ID, "admin")
			slog.Info("bootstrap admin assigned", "email", cfg.BootstrapAdmin)
		}
	}

	healthHandler := handler.NewHealthHandler(db, rdb)

	router := handler.NewRouter(handler.Deps{
		UserSvc:        userSvc,
		AuthSvc:        authSvc,
		RBACSvc:        rbacSvc,
		AdminSvc:       adminSvc,
		Redis:          rdb,
		Secret:         cfg.JWTSecret,
		IsProd:         cfg.IsProduction(),
		AllowedOrigins: cfg.AllowedOrigins,
		HealthHandler:  healthHandler,
	})

	srv := &http.Server{
		Addr:         ":" + cfg.Port,
		Handler:      router,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		slog.Info("server starting", "addr", srv.Addr, "env", cfg.Env)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		slog.Info("shutdown signal received")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	return srv.Shutdown(shutdownCtx)
}
EOF
}

write_62_internal_testutil_db_go() {
cat > internal/testutil/db.go <<'EOF'
package testutil

import (
	"testing"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"__GO_MODULE__/internal/model"
)

func NewTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file::memory:?cache=shared&_fk=1"), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	if err != nil {
		t.Fatalf("open test db: %v", err)
	}
	if err := db.AutoMigrate(
		&model.User{}, &model.RefreshToken{},
		&model.OneTimeToken{}, &model.Role{}, &model.Permission{},
	); err != nil {
		t.Fatalf("migrate test db: %v", err)
	}
	t.Cleanup(func() {
		sqlDB, _ := db.DB()
		_ = sqlDB.Close()
	})
	return db
}
EOF
}

write_63_tests_repository_user_test_go() {
cat > tests/repository/user_test.go <<'EOF'
package repository_test

import (
	"context"
	"errors"
	"testing"

	"__GO_MODULE__/internal/model"
	"__GO_MODULE__/internal/repository"
	userrepo "__GO_MODULE__/internal/repository/user"
	"__GO_MODULE__/internal/testutil"
)

func TestUserRepository_CreateAndGet(t *testing.T) {
	db := testutil.NewTestDB(t)
	repo := userrepo.New(db)
	ctx := context.Background()

	u := &model.User{Name: "Alice", Email: "alice@x.com", Password: "hash", Active: true}
	if err := repo.Create(ctx, u); err != nil {
		t.Fatalf("create: %v", err)
	}
	if u.ID == 0 {
		t.Fatal("expected ID")
	}

	got, err := repo.GetByID(ctx, u.ID)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.Email != "alice@x.com" {
		t.Errorf("want alice@x.com, got %s", got.Email)
	}
}

func TestUserRepository_NotFound(t *testing.T) {
	db := testutil.NewTestDB(t)
	repo := userrepo.New(db)

	_, err := repo.GetByID(context.Background(), 9999)
	if !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}
EOF
}

write_64_tests_service_user_test_go() {
cat > tests/service/user_test.go <<'EOF'
package service_test

import (
	"context"
	"errors"
	"testing"

	"__GO_MODULE__/internal/dto"
	"__GO_MODULE__/internal/email"
	refreshtokenrepo "__GO_MODULE__/internal/repository/refresh_token"
	rbacrepo "__GO_MODULE__/internal/repository/rbac"
	tokenrepo "__GO_MODULE__/internal/repository/token"
	userrepo "__GO_MODULE__/internal/repository/user"
	"__GO_MODULE__/internal/service"
	authsvc "__GO_MODULE__/internal/service/auth"
	rbacsvc "__GO_MODULE__/internal/service/rbac"
	usersvc "__GO_MODULE__/internal/service/user"
	"__GO_MODULE__/internal/testutil"
)

type noopMailer struct{}

func (n *noopMailer) Send(_ context.Context, _ email.Message) error { return nil }

func TestUserService_Create_DuplicateEmail(t *testing.T) {
	db := testutil.NewTestDB(t)
	userRepo := userrepo.New(db)
	refreshRepo := refreshtokenrepo.New(db)
	tokenRepo := tokenrepo.New(db)
	rbacRepo := rbacrepo.New(db)

	rbacSvc := rbacsvc.New(rbacRepo, nil, nil)
	authSvc := authsvc.New(userRepo, refreshRepo, tokenRepo, &noopMailer{},
		"secret", 3600, 24*3600, "http://x")
	userSvc := usersvc.New(userRepo, authSvc, rbacSvc, nil)

	ctx := context.Background()
	req := dto.CreateUserRequest{Name: "Alice", Email: "a@x.com", Password: "password123"}
	if _, err := userSvc.Create(ctx, req); err != nil {
		t.Fatalf("first create: %v", err)
	}
	_, err := userSvc.Create(ctx, req)
	if !errors.Is(err, service.ErrEmailTaken) {
		t.Fatalf("want ErrEmailTaken, got %v", err)
	}
}
EOF
}

write_65__github_workflows_ci_yml() {
cat > .github/workflows/ci.yml <<'EOF'
name: CI

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

env:
  GO_VERSION: "1.26"

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: ${{ env.GO_VERSION }}
          cache: true
      - uses: golangci/golangci-lint-action@v6
        with:
          version: latest
          args: --timeout=5m

  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: starter_test
        ports: [5432:5432]
        options: >-
          --health-cmd "pg_isready -U postgres"
          --health-interval 5s
          --health-retries 10
      redis:
        image: redis:7-alpine
        ports: [6379:6379]
        options: >-
          --health-cmd "redis-cli ping"
          --health-interval 5s
          --health-retries 10
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: ${{ env.GO_VERSION }}
          cache: true
      - run: go mod download
      - run: go vet ./...
      - name: Test
        env:
          DATABASE_URL: host=localhost user=postgres password=postgres dbname=starter_test port=5432 sslmode=disable
          REDIS_URL: redis://localhost:6379/0
          JWT_SECRET: test-secret-for-ci
        run: go test ./tests/... -race -count=1 -coverprofile=coverage.out -covermode=atomic
      - run: go tool cover -func=coverage.out
      - uses: actions/upload-artifact@v4
        with:
          name: coverage
          path: coverage.out

  build:
    runs-on: ubuntu-latest
    needs: [lint, test]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: ${{ env.GO_VERSION }}
          cache: true
      - run: CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o bin/api ./cmd/api
      - uses: actions/upload-artifact@v4
        with:
          name: api-binary
          path: bin/api

  security:
    runs-on: ubuntu-latest
    needs: [build]
    steps:
      - uses: actions/checkout@v4
      - uses: aquasecurity/trivy-action@master
        with:
          scan-type: fs
          scan-ref: .
          severity: CRITICAL,HIGH
          exit-code: "1"
          ignore-unfixed: true
      - uses: golang/govulncheck-action@v1
        with:
          go-version-input: ${{ env.GO_VERSION }}
EOF
}

write_66_README_md() {
cat > README.md <<'EOF'
# Go Starter

Gin + GORM REST API starter with JWT authentication, refresh tokens, email
verification, password reset, RBAC, Redis caching, Prometheus metrics, tests,
Docker, and GitHub Actions CI.

## Run the project

Copy the example configuration and install Go dependencies:

```sh
cp .env.example .env
go mod tidy
```

Start the API and its dependencies with Docker Compose:

```sh
make docker-up
curl http://localhost:8080/health
```

Useful commands:

```sh
make run       # run the API locally
make build     # build bin/api
make test      # run tests with the race detector
make swagger   # generate OpenAPI files in docs/
make docker-logs
make docker-down
```

`make run` expects PostgreSQL and Redis to be available and the required
variables in `.env` to be set. The default local services are provided by
`make docker-up`.

## Layout

Feature folders in `internal/repository/` and `internal/service/`:

- `internal/repository/user/`         — user repository
- `internal/repository/token/`        — one-time token repository
- `internal/repository/refresh_token/`— refresh token repository
- `internal/repository/rbac/`         — roles & permissions repository
- `internal/service/user/`            — user service
- `internal/service/auth/`            — auth + notifier
- `internal/service/rbac/`            — RBAC service
- `internal/service/admin/`           — admin service
- `internal/service/cleanup/`         — background cleanup

All tests live under `tests/`; the only test helper under `internal/` is
`internal/testutil/db.go`.
EOF
}
generate_project() {
  # Use the GitHub URL everywhere:
#   https://github.com/owner/repo.git -> github.com/owner/repo
MODULE="${GITHUB_URL#https://}"
MODULE="${MODULE%.git}"
MODULE="${MODULE%/}"

# Project folder comes from the repository name.
ROOT="${MODULE##*/}"

echo "==> GitHub URL: $GITHUB_URL"
echo "==> Creating $ROOT/"
echo "==> Go module: $MODULE"
rm -rf "$ROOT"
mkdir -p "$ROOT"
cd "$ROOT"

# ─────────────────────────────────────────────────────────────
# Directory tree
# ─────────────────────────────────────────────────────────────
mkdir -p \
  cmd/api \
  cmd/atlas-loader \
  internal/config \
  internal/database \
  internal/database/migrations \
  internal/cache \
  internal/metrics \
  internal/email \
  internal/rbac \
  internal/model \
  internal/dto \
  internal/repository/user \
  internal/repository/token \
  internal/repository/refresh_token \
  internal/repository/rbac \
  internal/service/user \
  internal/service/auth \
  internal/service/rbac \
  internal/service/admin \
  internal/service/cleanup \
  internal/handler \
  internal/middleware \
  internal/testutil \
  tests/repository \
  tests/service \
  tests/handler \
  pkg/jwt \
  observability \
  docs \
  .github/workflows

touch internal/database/migrations/.gitkeep
touch docs/.gitkeep

  write_01_docs_docs_go
  write_02_go_mod
  write_03__gitignore
  write_04__dockerignore
  write_05__env_example
  write_06_Makefile
  write_07_Dockerfile
  write_08_docker_compose_yml
  write_09_observability_prometheus_yml
  write_10_atlas_hcl
  write_11__golangci_yml
  write_12_pkg_jwt_jwt_go
  write_13_internal_config_config_go
  write_14_internal_database_database_go
  write_15_internal_database_seed_go
  write_16_internal_rbac_permissions_go
  write_17_internal_model_user_go
  write_18_internal_model_refresh_token_go
  write_19_internal_model_token_go
  write_20_internal_model_role_go
  write_21_internal_dto_user_go
  write_22_internal_dto_auth_go
  write_23_internal_dto_admin_go
  write_24_internal_email_email_go
  write_25_internal_email_console_go
  write_26_internal_email_smtp_go
  write_27_internal_metrics_metrics_go
  write_28_internal_cache_redis_go
  write_29_internal_cache_rbac_go
  write_30_internal_cache_user_go
  write_31_internal_cache_singleflight_go
  write_32_internal_cache_lock_go
  write_33_internal_repository_errors_go
  write_34_internal_repository_user_user_go
  write_35_internal_repository_token_token_go
  write_36_internal_repository_refresh_token_refresh_token_go
  write_37_internal_repository_rbac_rbac_go
  write_38_internal_service_errors_go
  write_39_internal_service_auth_auth_go
  write_40_internal_service_auth_notifier_go
  write_41_internal_service_user_user_go
  write_42_internal_service_rbac_rbac_go
  write_43_internal_service_admin_admin_go
  write_44_internal_service_cleanup_cleanup_go
  write_45_internal_middleware_auth_go
  write_46_internal_middleware_rbac_go
  write_47_internal_middleware_logging_go
  write_48_internal_middleware_recovery_go
  write_49_internal_middleware_metrics_go
  write_50_internal_middleware_ratelimit_go
  write_51_internal_middleware_security_go
  write_52_internal_middleware_cors_go
  write_53_internal_middleware_bodylimit_go
  write_54_internal_handler_response_go
  write_55_internal_handler_user_go
  write_56_internal_handler_auth_go
  write_57_internal_handler_admin_go
  write_58_internal_handler_health_go
  write_59_internal_handler_router_go
  write_60_cmd_atlas_loader_main_go
  write_61_cmd_api_main_go
  write_62_internal_testutil_db_go
  write_63_tests_repository_user_test_go
  write_64_tests_service_user_test_go
  write_65__github_workflows_ci_yml
  write_66_README_md

# ─────────────────────────────────────────────────────────────
# Apply selected Go module to generated imports
# ─────────────────────────────────────────────────────────────
while IFS= read -r -d '' file; do
  tmp="${file}.tmp"
  sed "s|__GO_MODULE__|${MODULE}|g" "$file" > "$tmp"
  mv "$tmp" "$file"
done < <(find . -type f -name '*.go' -print0)

# Configure the generated project to use the same GitHub repository URL.
if command -v git >/dev/null 2>&1; then
  git init -q
  git remote remove origin >/dev/null 2>&1 || true
  git remote add origin "$GITHUB_URL"
fi

  echo "==> Generated $ROOT with module $MODULE"
  echo "==> Git remote origin: $GITHUB_URL"
}

generate_project
