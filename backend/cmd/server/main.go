package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/clipshare/backend/internal/auth"
	"github.com/clipshare/backend/internal/pairing"
	"github.com/clipshare/backend/internal/store"
	"github.com/clipshare/backend/internal/ws"
)

func main() {
	var (
		addr      = flag.String("addr", ":8080", "HTTP service address")
		dbURL     = flag.String("db", getEnv("DATABASE_URL", "postgres://localhost/clipshare?sslmode=disable"), "PostgreSQL connection URL")
		redisURL  = flag.String("redis", getEnv("REDIS_URL", "localhost:6379"), "Redis connection URL")
		jwtSecret = flag.String("jwt-secret", getEnv("JWT_SECRET", "CHANGE_ME_IN_PRODUCTION"), "JWT signing secret")
	)
	flag.Parse()

	// Initialize store
	db, err := store.NewPostgres(*dbURL)
	if err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}
	defer db.Close()

	if err := db.Migrate(); err != nil {
		log.Fatalf("Failed to run migrations: %v", err)
	}

	redis, err := store.NewRedis(*redisURL)
	if err != nil {
		log.Fatalf("Failed to connect to Redis: %v", err)
	}
	defer redis.Close()

	// Initialize services
	authService := auth.NewService(db, []byte(*jwtSecret))
	pairingService := pairing.NewService(db, redis, authService)
	hub := ws.NewHub(db, redis)

	// Start WebSocket hub
	go hub.Run()

	// Setup HTTP routes
	mux := http.NewServeMux()

	// Health checks
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	// Pairing endpoints
	mux.HandleFunc("POST /v1/pair/start", pairingService.StartPairing)
	mux.HandleFunc("GET /pair", func(w http.ResponseWriter, r *http.Request) {
		ws.ServePairingWS(hub, pairingService, w, r)
	})

	// Device WebSocket
	mux.HandleFunc("GET /ws", func(w http.ResponseWriter, r *http.Request) {
		ws.ServeDeviceWS(hub, authService, w, r)
	})

	// Create server
	// Note: Don't set ReadTimeout/WriteTimeout for WebSocket support
	// WebSocket connections need to stay open indefinitely
	srv := &http.Server{
		Addr:        *addr,
		Handler:     mux,
		IdleTimeout: 120 * time.Second,
	}

	// Start server in goroutine
	go func() {
		log.Printf("Starting server on %s", *addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server failed: %v", err)
		}
	}()

	// Wait for interrupt signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down server...")

	// Graceful shutdown
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}

	log.Println("Server exited")
}

func getEnv(key, defaultVal string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultVal
}
