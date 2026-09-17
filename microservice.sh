#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

SERVICES_DIR="services"
if command -v go >/dev/null 2>&1; then
	DETECTED_GO_VERSION="$(go env GOVERSION 2>/dev/null | sed 's/^go//')"
else
	DETECTED_GO_VERSION="1.26"
fi

GO_VERSION="${GO_VERSION:-$DETECTED_GO_VERSION}"
AUTH_SERVICE="auth-service"
AUTH_PORT="8081"
DEFAULT_PORT="8080"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}==>${NC} $*"; }
success() { echo -e "${GREEN}==>${NC} $*"; }
warn()    { echo -e "${YELLOW}==>${NC} $*"; }
error()   { echo -e "${RED}ERROR:${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

validate_service() {
	[[ "$1" =~ ^[a-z][a-z0-9-]*$ ]] ||
		die "Invalid service name '$1'. Use lowercase kebab-case."
}

validate_port() {
	[[ "$1" =~ ^[0-9]+$ ]] || die "Invalid port '$1'"
	(( "$1" >= 1 && "$1" <= 65535 )) || die "Port must be between 1 and 65535"
}

repo_module() {
	if [[ -f .microservices.conf ]]; then
		# shellcheck disable=SC1091
		source .microservices.conf
		[[ -n "${REPO_MODULE:-}" ]] && {
			echo "$REPO_MODULE"
			return
		}
	fi

	die "Repository is not initialized. Run: make init:module github.com/owner/repo"
}

write_service_makefile() {
	local path="$1"

	cat > "$path/Makefile" <<'EOF'
SHELL := /bin/bash

.PHONY: run build test tidy fmt vet clean

run:
	go run ./cmd/api

build:
	mkdir -p bin
	go build -o bin/service ./cmd/api

test:
	go test ./... -race -count=1

tidy:
	go mod tidy

fmt:
	go fmt ./...

vet:
	go vet ./...

clean:
	rm -rf bin coverage.out coverage.html
EOF
}

write_common_files() {
	local path="$1"
	local service="$2"
	local module="$3"
	local port="$4"

	cat > "$path/go.mod" <<EOF
module $module

go $GO_VERSION

require (
	github.com/go-chi/chi/v5 v5.2.3
	github.com/golang-jwt/jwt/v5 v5.3.0
	github.com/joho/godotenv v1.5.1
	gorm.io/driver/postgres v1.6.0
	gorm.io/gorm v1.31.1
)
EOF

	cat > "$path/.env.example" <<EOF
APP_NAME=$service
ENV=development
PORT=$port

DATABASE_URL=host=localhost user=postgres password=postgres dbname=${service//-/_} port=5432 sslmode=disable TimeZone=UTC

JWT_SECRET=replace-with-at-least-32-random-bytes
JWT_ISSUER=go-api-auth
JWT_AUDIENCE=go-api
ACCESS_TOKEN_TTL=15m

AUTH_SERVICE_URL=http://localhost:$AUTH_PORT
EOF

	cat > "$path/internal/config/config.go" <<'EOF'
package config

import (
	"os"
	"time"

	"github.com/joho/godotenv"
)

type Config struct {
	AppName        string
	Env            string
	Port           string
	DatabaseURL    string
	JWTSecret      string
	JWTIssuer      string
	JWTAudience    string
	AccessTokenTTL time.Duration
	AuthServiceURL string
}

func Load() *Config {
	_ = godotenv.Load()

	return &Config{
		AppName:        env("APP_NAME", "service"),
		Env:            env("ENV", "development"),
		Port:           env("PORT", "8080"),
		DatabaseURL:    env("DATABASE_URL", ""),
		JWTSecret:      env("JWT_SECRET", ""),
		JWTIssuer:      env("JWT_ISSUER", "go-api-auth"),
		JWTAudience:    env("JWT_AUDIENCE", "go-api"),
		AccessTokenTTL: duration("ACCESS_TOKEN_TTL", 15*time.Minute),
		AuthServiceURL: env("AUTH_SERVICE_URL", "http://localhost:8081"),
	}
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func duration(key string, fallback time.Duration) time.Duration {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}

	parsed, err := time.ParseDuration(value)
	if err != nil {
		return fallback
	}

	return parsed
}
EOF

	cat > "$path/internal/database/database.go" <<'EOF'
package database

import (
	"fmt"
	"time"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

func New(dsn string) (*gorm.DB, error) {
	if dsn == "" {
		return nil, fmt.Errorf("DATABASE_URL is required")
	}

	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		return nil, fmt.Errorf("connect database: %w", err)
	}

	sqlDB, err := db.DB()
	if err != nil {
		return nil, fmt.Errorf("database handle: %w", err)
	}

	sqlDB.SetMaxOpenConns(25)
	sqlDB.SetMaxIdleConns(10)
	sqlDB.SetConnMaxLifetime(30 * time.Minute)

	return db, nil
}
EOF

	cat > "$path/internal/auth/claims.go" <<'EOF'
package auth

import (
	"context"
	"fmt"

	"github.com/golang-jwt/jwt/v5"
)

type Claims struct {
	UserID      uint     `json:"uid"`
	Email       string   `json:"email"`
	Roles       []string `json:"roles"`
	Permissions []string `json:"permissions"`
	jwt.RegisteredClaims
}

func (c *Claims) HasRole(role string) bool {
	for _, value := range c.Roles {
		if value == role {
			return true
		}
	}
	return false
}

func (c *Claims) HasPermission(permission string) bool {
	for _, value := range c.Permissions {
		if value == permission {
			return true
		}
	}
	return false
}

type contextKey string

const claimsKey contextKey = "auth.claims"

func WithClaims(ctx context.Context, claims *Claims) context.Context {
	return context.WithValue(ctx, claimsKey, claims)
}

func ClaimsFromContext(ctx context.Context) (*Claims, bool) {
	claims, ok := ctx.Value(claimsKey).(*Claims)
	return claims, ok
}

type TokenManager struct {
	secret   []byte
	issuer   string
	audience string
}

func NewTokenManager(secret, issuer, audience string) (*TokenManager, error) {
	if len(secret) < 32 {
		return nil, fmt.Errorf("JWT_SECRET must be at least 32 bytes")
	}

	return &TokenManager{
		secret:   []byte(secret),
		issuer:   issuer,
		audience: audience,
	}, nil
}

func (m *TokenManager) Parse(raw string) (*Claims, error) {
	token, err := jwt.ParseWithClaims(
		raw,
		&Claims{},
		func(token *jwt.Token) (any, error) {
			if token.Method.Alg() != jwt.SigningMethodHS256.Alg() {
				return nil, fmt.Errorf("unexpected signing method")
			}
			return m.secret, nil
		},
		jwt.WithIssuer(m.issuer),
		jwt.WithAudience(m.audience),
		jwt.WithExpirationRequired(),
	)
	if err != nil {
		return nil, err
	}

	claims, ok := token.Claims.(*Claims)
	if !ok || !token.Valid {
		return nil, fmt.Errorf("invalid token")
	}

	return claims, nil
}
EOF

	cat > "$path/internal/middleware/auth.go" <<EOF
package middleware

import (
	"net/http"
	"strings"

	appauth "$module/internal/auth"
)

type Auth struct {
	tokens *appauth.TokenManager
}

func NewAuth(tokens *appauth.TokenManager) *Auth {
	return &Auth{tokens: tokens}
}

func (m *Auth) Authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		value := r.Header.Get("Authorization")
		if !strings.HasPrefix(value, "Bearer ") {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		claims, err := m.tokens.Parse(strings.TrimSpace(strings.TrimPrefix(value, "Bearer ")))
		if err != nil {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		next.ServeHTTP(w, r.WithContext(appauth.WithClaims(r.Context(), claims)))
	})
}

func RequirePermission(permission string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, ok := appauth.ClaimsFromContext(r.Context())
			if !ok {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}

			if !claims.HasPermission(permission) {
				http.Error(w, "forbidden", http.StatusForbidden)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}

func RequireRole(role string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, ok := appauth.ClaimsFromContext(r.Context())
			if !ok {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}

			if !claims.HasRole(role) {
				http.Error(w, "forbidden", http.StatusForbidden)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}
EOF

	cat > "$path/internal/handler/response.go" <<'EOF'
package handler

import (
	"encoding/json"
	"net/http"
)

func JSON(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}
EOF

	write_service_makefile "$path"

	cat > "$path/Dockerfile" <<EOF
FROM golang:${GO_VERSION}-alpine AS builder

WORKDIR /app
COPY go.mod go.sum* ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/service ./cmd/api

FROM alpine:3.21
RUN apk add --no-cache ca-certificates tzdata && adduser -D -u 1000 app

WORKDIR /app
COPY --from=builder /out/service /app/service

USER app
EXPOSE $port
ENTRYPOINT ["/app/service"]
EOF
}

write_standard_service() {
	local path="$1"
	local service="$2"
	local module="$3"
	local port="$4"

	write_common_files "$path" "$service" "$module" "$port"

	cat > "$path/internal/handler/router.go" <<EOF
package handler

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"

	"$module/internal/middleware"
)

func NewRouter(auth *middleware.Auth) http.Handler {
	r := chi.NewRouter()

	r.Use(chimw.RequestID)
	r.Use(chimw.RealIP)
	r.Use(chimw.Recoverer)

	r.Get("/health", func(w http.ResponseWriter, r *http.Request) {
		JSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	r.Group(func(r chi.Router) {
		r.Use(auth.Authenticate)

		r.Get("/api/v1/me", func(w http.ResponseWriter, r *http.Request) {
			JSON(w, http.StatusOK, map[string]string{"status": "authenticated"})
		})

		// Example:
		// r.With(
		//     middleware.RequirePermission("$service.read"),
		// ).Get("/api/v1/resources", handler)
	})

	return r
}
EOF

	cat > "$path/cmd/api/main.go" <<EOF
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

	"$module/internal/auth"
	"$module/internal/config"
	"$module/internal/database"
	"$module/internal/handler"
	"$module/internal/middleware"
)

func main() {
	if err := run(); err != nil {
		slog.Error("service stopped", "error", err)
		os.Exit(1)
	}
}

func run() error {
	cfg := config.Load()

	db, err := database.New(cfg.DatabaseURL)
	if err != nil {
		return err
	}

	sqlDB, err := db.DB()
	if err != nil {
		return err
	}
	defer sqlDB.Close()

	tokens, err := auth.NewTokenManager(
		cfg.JWTSecret,
		cfg.JWTIssuer,
		cfg.JWTAudience,
	)
	if err != nil {
		return err
	}

	authMiddleware := middleware.NewAuth(tokens)
	router := handler.NewRouter(authMiddleware)

	server := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           router,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errs := make(chan error, 1)

	go func() {
		slog.Info("service started", "name", cfg.AppName, "port", cfg.Port)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errs <- err
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	select {
	case err := <-errs:
		return err
	case <-stop:
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	return server.Shutdown(ctx)
}
EOF
}

write_auth_service() {
	local path="$1"
	local module="$2"

	write_common_files "$path" "$AUTH_SERVICE" "$module" "$AUTH_PORT"

	cat >> "$path/go.mod" <<'EOF'
require golang.org/x/crypto v0.36.0
EOF

	cat >> "$path/.env.example" <<'EOF'

ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=ChangeThisAdminPassword123!
EOF

	cat > "$path/internal/model/models.go" <<'EOF'
package model

import "time"

type User struct {
	ID           uint   `gorm:"primaryKey"`
	Email        string `gorm:"size:255;uniqueIndex;not null"`
	PasswordHash string `gorm:"not null"`
	IsActive     bool   `gorm:"default:true;not null"`
	Roles        []Role `gorm:"many2many:user_roles;"`
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

type Role struct {
	ID          uint         `gorm:"primaryKey"`
	Name        string       `gorm:"size:100;uniqueIndex;not null"`
	Description string       `gorm:"size:255"`
	Permissions []Permission `gorm:"many2many:role_permissions;"`
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

type Permission struct {
	ID          uint   `gorm:"primaryKey"`
	Name        string `gorm:"size:150;uniqueIndex;not null"`
	Description string `gorm:"size:255"`
	CreatedAt   time.Time
	UpdatedAt   time.Time
}
EOF

	cat > "$path/internal/repository/user.go" <<EOF
package repository

import (
	"context"
	"strings"

	"$module/internal/model"

	"gorm.io/gorm"
)

type UserRepository struct {
	db *gorm.DB
}

func NewUserRepository(db *gorm.DB) *UserRepository {
	return &UserRepository{db: db}
}

func (r *UserRepository) FindByEmail(ctx context.Context, email string) (*model.User, error) {
	var user model.User

	err := r.db.WithContext(ctx).
		Preload("Roles.Permissions").
		Where("email = ?", strings.ToLower(strings.TrimSpace(email))).
		First(&user).
		Error

	if err != nil {
		return nil, err
	}

	return &user, nil
}

func (r *UserRepository) FindByID(ctx context.Context, id uint) (*model.User, error) {
	var user model.User

	err := r.db.WithContext(ctx).
		Preload("Roles.Permissions").
		First(&user, id).
		Error

	if err != nil {
		return nil, err
	}

	return &user, nil
}
EOF

	cat > "$path/internal/auth/generate.go" <<'EOF'
package auth

import (
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func (m *TokenManager) Generate(
	userID uint,
	email string,
	roles []string,
	permissions []string,
	ttl time.Duration,
) (string, error) {
	now := time.Now()

	claims := Claims{
		UserID:      userID,
		Email:       email,
		Roles:       roles,
		Permissions: permissions,
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    m.issuer,
			Audience:  jwt.ClaimStrings{m.audience},
			Subject:   fmt.Sprintf("%d", userID),
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(ttl)),
		},
	}

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(m.secret)
}
EOF

	cat > "$path/internal/service/auth.go" <<EOF
package service

import (
	"context"
	"errors"
	"sort"
	"time"

	"$module/internal/auth"
	"$module/internal/repository"

	"golang.org/x/crypto/bcrypt"
)

var ErrInvalidCredentials = errors.New("invalid credentials")

type AuthService struct {
	users  *repository.UserRepository
	tokens *auth.TokenManager
}

type LoginResult struct {
	AccessToken string   \`json:"access_token"\`
	TokenType   string   \`json:"token_type"\`
	ExpiresIn   int64    \`json:"expires_in"\`
	UserID      uint     \`json:"user_id"\`
	Email       string   \`json:"email"\`
	Roles       []string \`json:"roles"\`
	Permissions []string \`json:"permissions"\`
}

func NewAuthService(users *repository.UserRepository, tokens *auth.TokenManager) *AuthService {
	return &AuthService{users: users, tokens: tokens}
}

func (s *AuthService) Login(ctx context.Context, email, password string, ttl time.Duration) (*LoginResult, error) {
	user, err := s.users.FindByEmail(ctx, email)
	if err != nil || !user.IsActive {
		return nil, ErrInvalidCredentials
	}

	if bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(password)) != nil {
		return nil, ErrInvalidCredentials
	}

	roles := make([]string, 0, len(user.Roles))
	permissionsSet := map[string]struct{}{}

	for _, role := range user.Roles {
		roles = append(roles, role.Name)
		for _, permission := range role.Permissions {
			permissionsSet[permission.Name] = struct{}{}
		}
	}

	permissions := make([]string, 0, len(permissionsSet))
	for name := range permissionsSet {
		permissions = append(permissions, name)
	}

	sort.Strings(roles)
	sort.Strings(permissions)

	token, err := s.tokens.Generate(user.ID, user.Email, roles, permissions, ttl)
	if err != nil {
		return nil, err
	}

	return &LoginResult{
		AccessToken: token,
		TokenType: "Bearer",
		ExpiresIn: int64(ttl.Seconds()),
		UserID: user.ID,
		Email: user.Email,
		Roles: roles,
		Permissions: permissions,
	}, nil
}
EOF

	cat > "$path/internal/handler/auth.go" <<EOF
package handler

import (
	"encoding/json"
	"net/http"
	"time"

	"$module/internal/auth"
	"$module/internal/service"
)

type AuthHandler struct {
	service *service.AuthService
	ttl     time.Duration
}

func NewAuthHandler(service *service.AuthService, ttl time.Duration) *AuthHandler {
	return &AuthHandler{service: service, ttl: ttl}
}

type loginRequest struct {
	Email    string \`json:"email"\`
	Password string \`json:"password"\`
}

func (h *AuthHandler) Login(w http.ResponseWriter, r *http.Request) {
	var input loginRequest

	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		http.Error(w, "invalid request", http.StatusBadRequest)
		return
	}

	result, err := h.service.Login(r.Context(), input.Email, input.Password, h.ttl)
	if err != nil {
		http.Error(w, "invalid credentials", http.StatusUnauthorized)
		return
	}

	JSON(w, http.StatusOK, result)
}

func (h *AuthHandler) Me(w http.ResponseWriter, r *http.Request) {
	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	JSON(w, http.StatusOK, claims)
}
EOF

	cat > "$path/internal/handler/admin.go" <<EOF
package handler

import (
	"encoding/json"
	"net/http"
	"strings"

	"$module/internal/model"

	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
)

type AdminHandler struct {
	db *gorm.DB
}

func NewAdminHandler(db *gorm.DB) *AdminHandler {
	return &AdminHandler{db: db}
}

type createUserRequest struct {
	Email    string \`json:"email"\`
	Password string \`json:"password"\`
	RoleIDs  []uint \`json:"role_ids"\`
}

func (h *AdminHandler) CreateUser(w http.ResponseWriter, r *http.Request) {
	var input createUserRequest
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		http.Error(w, "invalid request", http.StatusBadRequest)
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(input.Password), bcrypt.DefaultCost)
	if err != nil {
		http.Error(w, "failed to hash password", http.StatusInternalServerError)
		return
	}

	user := model.User{
		Email: strings.ToLower(strings.TrimSpace(input.Email)),
		PasswordHash: string(hash),
		IsActive: true,
	}

	if err := h.db.WithContext(r.Context()).Create(&user).Error; err != nil {
		http.Error(w, "failed to create user", http.StatusConflict)
		return
	}

	if len(input.RoleIDs) > 0 {
		var roles []model.Role
		if err := h.db.Find(&roles, input.RoleIDs).Error; err == nil {
			_ = h.db.Model(&user).Association("Roles").Replace(&roles)
		}
	}

	user.PasswordHash = ""
	JSON(w, http.StatusCreated, user)
}

func (h *AdminHandler) ListRoles(w http.ResponseWriter, r *http.Request) {
	var roles []model.Role
	if err := h.db.Preload("Permissions").Find(&roles).Error; err != nil {
		http.Error(w, "failed to list roles", http.StatusInternalServerError)
		return
	}
	JSON(w, http.StatusOK, roles)
}

func (h *AdminHandler) ListPermissions(w http.ResponseWriter, r *http.Request) {
	var permissions []model.Permission
	if err := h.db.Find(&permissions).Error; err != nil {
		http.Error(w, "failed to list permissions", http.StatusInternalServerError)
		return
	}
	JSON(w, http.StatusOK, permissions)
}
EOF

	cat > "$path/internal/database/migrate.go" <<EOF
package database

import (
	"fmt"
	"os"
	"strings"

	"$module/internal/model"

	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
)

func MigrateAndSeed(db *gorm.DB) error {
	if err := db.AutoMigrate(
		&model.User{},
		&model.Role{},
		&model.Permission{},
	); err != nil {
		return fmt.Errorf("auto migrate: %w", err)
	}

	permissions := []string{
		"users.read",
		"users.create",
		"users.update",
		"users.delete",
		"roles.read",
		"roles.create",
		"roles.update",
		"roles.delete",
		"permissions.read",
		"permissions.assign",
	}

	for _, name := range permissions {
		if err := db.FirstOrCreate(
			&model.Permission{},
			model.Permission{Name: name},
		).Error; err != nil {
			return err
		}
	}

	var all []model.Permission
	if err := db.Find(&all).Error; err != nil {
		return err
	}

	var adminRole model.Role
	if err := db.FirstOrCreate(
		&adminRole,
		model.Role{Name: "admin"},
	).Error; err != nil {
		return err
	}

	if err := db.Model(&adminRole).Association("Permissions").Replace(&all); err != nil {
		return err
	}

	email := strings.ToLower(strings.TrimSpace(os.Getenv("ADMIN_EMAIL")))
	password := os.Getenv("ADMIN_PASSWORD")

	if email == "" || password == "" {
		return nil
	}

	var count int64
	if err := db.Model(&model.User{}).Where("email = ?", email).Count(&count).Error; err != nil {
		return err
	}

	if count > 0 {
		return nil
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return err
	}

	user := model.User{
		Email: email,
		PasswordHash: string(hash),
		IsActive: true,
	}

	if err := db.Create(&user).Error; err != nil {
		return err
	}

	return db.Model(&user).Association("Roles").Append(&adminRole)
}
EOF

	cat > "$path/internal/handler/router.go" <<EOF
package handler

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"

	"$module/internal/middleware"
)

func NewRouter(
	authHandler *AuthHandler,
	adminHandler *AdminHandler,
	authMiddleware *middleware.Auth,
) http.Handler {
	r := chi.NewRouter()

	r.Use(chimw.RequestID)
	r.Use(chimw.RealIP)
	r.Use(chimw.Recoverer)

	r.Get("/health", func(w http.ResponseWriter, r *http.Request) {
		JSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	r.Route("/api/v1", func(r chi.Router) {
		r.Post("/auth/login", authHandler.Login)

		r.Group(func(r chi.Router) {
			r.Use(authMiddleware.Authenticate)

			r.Get("/auth/me", authHandler.Me)

			r.With(middleware.RequirePermission("users.create")).
				Post("/users", adminHandler.CreateUser)

			r.With(middleware.RequirePermission("roles.read")).
				Get("/roles", adminHandler.ListRoles)

			r.With(middleware.RequirePermission("permissions.read")).
				Get("/permissions", adminHandler.ListPermissions)
		})
	})

	return r
}
EOF

	cat > "$path/cmd/api/main.go" <<EOF
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

	"$module/internal/auth"
	"$module/internal/config"
	"$module/internal/database"
	"$module/internal/handler"
	"$module/internal/middleware"
	"$module/internal/repository"
	"$module/internal/service"
)

func main() {
	if err := run(); err != nil {
		slog.Error("auth service stopped", "error", err)
		os.Exit(1)
	}
}

func run() error {
	cfg := config.Load()

	db, err := database.New(cfg.DatabaseURL)
	if err != nil {
		return err
	}

	sqlDB, err := db.DB()
	if err != nil {
		return err
	}
	defer sqlDB.Close()

	if err := database.MigrateAndSeed(db); err != nil {
		return err
	}

	tokens, err := auth.NewTokenManager(
		cfg.JWTSecret,
		cfg.JWTIssuer,
		cfg.JWTAudience,
	)
	if err != nil {
		return err
	}

	users := repository.NewUserRepository(db)
	authService := service.NewAuthService(users, tokens)
	authHandler := handler.NewAuthHandler(authService, cfg.AccessTokenTTL)
	adminHandler := handler.NewAdminHandler(db)
	authMiddleware := middleware.NewAuth(tokens)

	router := handler.NewRouter(
		authHandler,
		adminHandler,
		authMiddleware,
	)

	server := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           router,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errs := make(chan error, 1)

	go func() {
		slog.Info("auth service started", "port", cfg.Port)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errs <- err
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	select {
	case err := <-errs:
		return err
	case <-stop:
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	return server.Shutdown(ctx)
}
EOF
}

create_dirs() {
	local path="$1"

	mkdir -p \
		"$path/cmd/api" \
		"$path/internal/auth" \
		"$path/internal/config" \
		"$path/internal/database" \
		"$path/internal/model" \
		"$path/internal/repository" \
		"$path/internal/service" \
		"$path/internal/handler" \
		"$path/internal/middleware" \
		"$path/internal/client" \
		"$path/tests"
}

create_service() {
	local service="${1:-}"
	shift || true

	[[ -n "$service" ]] || die "Service name is required"

	local port="$DEFAULT_PORT"

	while (( $# )); do
		case "$1" in
			--port)
				[[ $# -ge 2 ]] || die "--port requires a value"
				port="$2"
				shift 2
				;;
			*)
				die "Unknown option: $1"
				;;
		esac
	done

	validate_service "$service"
	validate_port "$port"

	local root_module
	root_module="$(repo_module)"

	local path="$SERVICES_DIR/$service"
	[[ ! -e "$path" ]] || die "Service already exists: $service"

	local module="$root_module/services/$service"

	info "Creating $service"
	create_dirs "$path"
	write_standard_service "$path" "$service" "$module" "$port"

	if command -v go >/dev/null 2>&1; then
		if ! (
			cd "$path"
			go mod tidy
		); then
			warn "go mod tidy skipped/failed; run 'make tidy:service $service' when dependencies are reachable"
		fi
		[[ -f go.work ]] && go work use "./$path"
	fi

	success "Created $service on port $port"
}

create_auth_service() {
	local root_module="$1"
	local path="$SERVICES_DIR/$AUTH_SERVICE"
	local module="$root_module/services/$AUTH_SERVICE"

	if [[ -d "$path" ]]; then
		warn "$AUTH_SERVICE already exists; skipping"
		return
	fi

	info "Creating default $AUTH_SERVICE"
	create_dirs "$path"
	write_auth_service "$path" "$module"

	if command -v go >/dev/null 2>&1; then
		if ! (
			cd "$path"
			go mod tidy
		); then
			warn "go mod tidy skipped/failed; run 'make tidy:service $AUTH_SERVICE' when dependencies are reachable"
		fi
		[[ -f go.work ]] && go work use "./$path"
	fi

	success "Created $AUTH_SERVICE on port $AUTH_PORT"
}

init_repo() {
	local module="${1:-}"
	[[ -n "$module" ]] || die "MODULE is required"

	module="${module#https://}"
	module="${module#http://}"
	module="${module%.git}"
	module="${module%/}"

	mkdir -p "$SERVICES_DIR"

	cat > .microservices.conf <<EOF
REPO_MODULE="$module"
EOF

	if command -v go >/dev/null 2>&1; then
		[[ -f go.work ]] || go work init
	else
		cat > go.work <<EOF
go $GO_VERSION
EOF
	fi

	create_auth_service "$module"

	success "Monorepo initialized"
	echo ""
	echo "Next:"
	echo "  cp services/auth-service/.env.example services/auth-service/.env"
	echo "  edit services/auth-service/.env"
	echo "  make run:service auth-service"
}

delete_service() {
	local service="${1:-}"
	[[ -n "$service" ]] || die "Service name is required"
	validate_service "$service"

	if [[ "$service" == "$AUTH_SERVICE" ]]; then
		die "Refusing to delete auth-service with this command"
	fi

	local path="$SERVICES_DIR/$service"
	[[ -d "$path" ]] || die "Service does not exist: $service"

	read -r -p "Delete $path? [y/N] " answer
	[[ "$answer" == "y" || "$answer" == "Y" ]] || return 0

	if command -v go >/dev/null 2>&1 && [[ -f go.work ]]; then
		go work edit -dropuse="./$path" 2>/dev/null || true
	fi

	rm -rf "$path"
	success "Deleted $service"
}

list_services() {
	echo ""
	echo "Services"
	echo "========"

	local found=false
	for path in "$SERVICES_DIR"/*; do
		[[ -d "$path" ]] || continue
		found=true
		echo "  - $(basename "$path")"
	done

	[[ "$found" == true ]] || echo "  No services found."
	echo ""
}

service_command() {
	local command="$1"
	local service="${2:-}"

	[[ -n "$service" ]] ||
		die "Service is required. Example: make $command:service auth-service"

	local path="$SERVICES_DIR/$service"
	[[ -d "$path" ]] || die "Service does not exist: $service"

	make -C "$path" "$command"
}

each_service() {
	local command="${1:-}"
	[[ -n "$command" ]] || die "Command required"

	for path in "$SERVICES_DIR"/*; do
		[[ -f "$path/Makefile" ]] || continue
		echo ""
		echo "==> $command $(basename "$path")"
		make -C "$path" "$command"
	done
}

workspace() {
	command -v go >/dev/null 2>&1 || die "Go is not installed"

	rm -f go.work
	go work init

	for path in "$SERVICES_DIR"/*; do
		[[ -f "$path/go.mod" ]] || continue
		go work use "./$path"
	done

	success "go.work rebuilt"
}

check_all() {
	each_service fmt
	each_service vet
	each_service test
	success "All checks passed"
}

doctor() {
	echo ""
	echo "Environment"
	echo "==========="

	for command in go git make docker; do
		if command -v "$command" >/dev/null 2>&1; then
			printf "  %-14s OK\n" "$command"
		else
			printf "  %-14s MISSING\n" "$command"
		fi
	done

	[[ -f .microservices.conf ]] && printf "  %-14s OK\n" "config" || printf "  %-14s MISSING\n" "config"
	[[ -f go.work ]] && printf "  %-14s OK\n" "go.work" || printf "  %-14s MISSING\n" "go.work"
	echo ""
}

show_help() {
	cat <<'EOF'

Go Microservices Generator
==========================

Maintained files:
  Makefile
  microservice.sh

Initialize monorepo and automatically create auth-service:

	make init:module github.com/hakhant21/go-api

Create another service:

  make create:service payment-service PORT=8082
  make create:service inventory-service PORT=8083
	make create:service payment-service PORT=8082
	make create:service inventory-service PORT=8083

Run:

	make run:service auth-service
	make run:service payment-service

Development:

	make build:service payment-service
	make test:service payment-service
	make tidy:service payment-service

All services:

  make build-all
  make test-all
  make tidy-all
  make fmt
  make vet
  make check

Management:

  make list
	make delete:service payment-service
  make workspace
  make doctor

Default auth-service:
  - Chi router
  - GORM + PostgreSQL
  - JWT access tokens
  - Users
  - Roles
  - Permissions
  - User <-> Role many-to-many
  - Role <-> Permission many-to-many
  - Default admin role
  - Admin user seeding from environment
  - Permission middleware
  - Role middleware

Auth endpoints:
  POST /api/v1/auth/login
  GET  /api/v1/auth/me
  POST /api/v1/users
  GET  /api/v1/roles
  GET  /api/v1/permissions

EOF
}

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
		init) init_repo "$@" ;;
		create|new) create_service "$@" ;;
		delete|remove) delete_service "$@" ;;
		list) list_services ;;
		run|build|test|tidy|clean|fmt|vet) service_command "$command" "$@" ;;
		each) each_service "$@" ;;
		workspace) workspace ;;
		check) check_all ;;
		doctor) doctor ;;
		help|-h|--help) show_help ;;
		*) die "Unknown command: $command" ;;
	esac
}

main "$@"
