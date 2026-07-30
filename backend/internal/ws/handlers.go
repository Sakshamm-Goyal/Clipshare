package ws

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/clipshare/backend/internal/auth"
	"github.com/clipshare/backend/internal/pairing"
	"github.com/gorilla/websocket"
)

// Rate limiter for pairing endpoint
var (
	pairingRateLimiter = &rateLimiter{
		requests: make(map[string][]time.Time),
		limit:    10,              // max requests
		window:   time.Minute * 5, // per 5 minutes
	}
)

type rateLimiter struct {
	mu       sync.Mutex
	requests map[string][]time.Time
	limit    int
	window   time.Duration
}

func (rl *rateLimiter) Allow(ip string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	now := time.Now()
	cutoff := now.Add(-rl.window)

	// Clean old requests
	var recent []time.Time
	for _, t := range rl.requests[ip] {
		if t.After(cutoff) {
			recent = append(recent, t)
		}
	}

	if len(recent) >= rl.limit {
		return false
	}

	rl.requests[ip] = append(recent, now)
	return true
}

// Allowed origins for CORS
var allowedOrigins = map[string]bool{
	"http://localhost:8080":  true,
	"https://localhost:8080": true,
	"http://localhost:3000":  true, // For development
	"https://clipshare.app":  true, // Production domain (example)
}

func isOriginAllowed(origin string) bool {
	// Allow empty origin (non-browser clients like mobile apps, native apps)
	if origin == "" {
		return true
	}

	// Check against whitelist
	if allowedOrigins[origin] {
		return true
	}

	// Allow localhost with any port for development
	if strings.HasPrefix(origin, "http://localhost:") ||
		strings.HasPrefix(origin, "https://localhost:") ||
		strings.HasPrefix(origin, "http://127.0.0.1:") ||
		strings.HasPrefix(origin, "https://127.0.0.1:") {
		return true
	}

	// Allow local network IPs (192.168.x.x, 10.x.x.x, 172.16-31.x.x) for development
	if strings.HasPrefix(origin, "http://192.168.") ||
		strings.HasPrefix(origin, "https://192.168.") ||
		strings.HasPrefix(origin, "http://10.") ||
		strings.HasPrefix(origin, "https://10.") ||
		strings.HasPrefix(origin, "http://172.") ||
		strings.HasPrefix(origin, "https://172.") {
		return true
	}

	return false
}

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		origin := r.Header.Get("Origin")
		allowed := isOriginAllowed(origin)
		if !allowed {
			log.Printf("Rejected origin: %s", origin)
		}
		return allowed
	},
}

// ServeDeviceWS handles WebSocket connections for authenticated devices
func ServeDeviceWS(hub *Hub, authService *auth.Service, w http.ResponseWriter, r *http.Request) {
	// Extract JWT from Authorization header or Sec-WebSocket-Protocol
	var tokenString string

	authHeader := r.Header.Get("Authorization")
	if authHeader != "" && strings.HasPrefix(authHeader, "Bearer ") {
		tokenString = strings.TrimPrefix(authHeader, "Bearer ")
	} else {
		// Try Sec-WebSocket-Protocol (for browsers/mobile apps)
		protocols := r.Header.Get("Sec-WebSocket-Protocol")
		parts := strings.Split(protocols, ",")
		for _, p := range parts {
			p = strings.TrimSpace(p)
			if strings.HasPrefix(p, "Bearer.") {
				tokenString = strings.TrimPrefix(p, "Bearer.")
				break
			}
		}
	}

	if tokenString == "" {
		log.Printf("Missing authentication token from %s", getClientIP(r))
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	// Validate token
	claims, err := authService.ValidateToken(tokenString)
	if err != nil {
		log.Printf("Invalid token from %s: %v", getClientIP(r), err)
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	// Validate device exists
	device, err := authService.ValidateDevice(claims.DeviceID)
	if err != nil {
		log.Printf("Device validation failed for %s: %v", claims.DeviceID, err)
		http.Error(w, "Forbidden", http.StatusForbidden)
		return
	}

	// Upgrade connection
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade failed: %v", err)
		return
	}

	// Create client
	client := &Client{
		hub:      hub,
		conn:     conn,
		send:     make(chan []byte, 256),
		deviceID: device.ID,
		userID:   device.UserID,
	}

	// Register client
	client.hub.register <- client

	// Update last seen
	go hub.db.UpdateDeviceLastSeen(device.ID)

	// Start pumps
	go client.writePump()
	go client.readPump()

	log.Printf("Device connected: %s (platform: %s)", device.ID, device.Platform)
}

// Store waiting pairing connections (Mac devices waiting for Android to scan)
var (
	pairingWaiters   = make(map[string]*websocket.Conn) // token -> Mac's connection
	pairingWaitersMu sync.Mutex
)

// ServePairingWS handles WebSocket connections during device pairing
func ServePairingWS(hub *Hub, pairingService *pairing.Service, w http.ResponseWriter, r *http.Request) {
	// Rate limiting
	clientIP := getClientIP(r)
	if !pairingRateLimiter.Allow(clientIP) {
		log.Printf("Rate limit exceeded for pairing from %s", clientIP)
		http.Error(w, "Too many requests", http.StatusTooManyRequests)
		return
	}

	token := r.URL.Query().Get("token")
	if token == "" {
		http.Error(w, "Missing token", http.StatusBadRequest)
		return
	}

	// Check if this is the originator (Mac) or the peer (Android)
	role := r.URL.Query().Get("role")

	// Validate token exists and not expired
	deviceID, devicePub, err := hub.db.GetPairToken(token)
	if err != nil {
		log.Printf("Invalid pairing token from %s: %v", clientIP, err)
		http.Error(w, "Invalid or expired token", http.StatusUnauthorized)
		return
	}

	// Upgrade connection
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade failed: %v", err)
		return
	}

	log.Printf("Pairing WebSocket connected for device %s from %s (role: %s)", deviceID, clientIP, role)

	// If this is the originator (Mac), store connection and wait
	if role == "originator" || role == "" {
		// Check if someone else is already waiting with this token
		pairingWaitersMu.Lock()
		existingConn := pairingWaiters[token]
		if existingConn == nil {
			// This is the Mac (originator) - store and wait
			pairingWaiters[token] = conn
			log.Printf("Stored originator pairing connection (total waiters: %d)", len(pairingWaiters))
			pairingWaitersMu.Unlock()

			log.Printf("Originator waiting for peer pairing connection")

			// Keep connection alive - wait for message or close
			// Set a long deadline for the originator
			conn.SetReadDeadline(time.Now().Add(10 * time.Minute))

			// Just wait - we'll get notified by the peer connection
			for {
				_, _, err := conn.ReadMessage()
				if err != nil {
					log.Printf("Originator connection closed: %v", err)
					break
				}
			}

			// Clean up
			pairingWaitersMu.Lock()
			delete(pairingWaiters, token)
			pairingWaitersMu.Unlock()
			conn.Close()
			return
		}
		pairingWaitersMu.Unlock()
	}

	// This is the peer (Android) - handle pairing
	// Note: We'll close the connection gracefully at the end after sending response

	// Set read deadline for pairing message (30 seconds)
	conn.SetReadDeadline(time.Now().Add(30 * time.Second))

	// Wait for peer info message
	_, message, err := conn.ReadMessage()
	if err != nil {
		log.Printf("Failed to read pairing message: %v", err)
		return
	}

	var peerInfo struct {
		DeviceID   string `json:"device_id"`
		DeviceName string `json:"device_name"`
		PublicKey  string `json:"public_key"`
		Platform   string `json:"platform"`
	}

	if err := json.Unmarshal(message, &peerInfo); err != nil {
		log.Printf("Invalid peer info format: %v", err)
		errorMsg, _ := json.Marshal(map[string]string{"error": "Invalid message format"})
		conn.WriteMessage(websocket.TextMessage, errorMsg)
		return
	}

	// Validate peer info
	if peerInfo.DeviceID == "" || peerInfo.PublicKey == "" || peerInfo.Platform == "" {
		log.Printf("Missing required fields in peer info")
		errorMsg, _ := json.Marshal(map[string]string{"error": "Missing required fields"})
		conn.WriteMessage(websocket.TextMessage, errorMsg)
		return
	}

	// Complete pairing
	origToken, peerToken, err := pairingService.CompletePairing(
		token,
		peerInfo.DeviceID,
		peerInfo.DeviceName,
		peerInfo.PublicKey,
		peerInfo.Platform,
	)
	if err != nil {
		log.Printf("Failed to complete pairing: %v", err)
		errorMsg, _ := json.Marshal(map[string]string{"error": err.Error()})
		conn.WriteMessage(websocket.TextMessage, errorMsg)
		return
	}

	log.Printf("Pairing tokens generated for %s and %s", deviceID, peerInfo.DeviceID)

	// Send success response to peer (Android)
	peerResponse := map[string]string{
		"status":          "success",
		"peer_token":      peerToken,
		"original_device": deviceID,
		"peer_device":     peerInfo.DeviceID,
		"device_pub":      devicePub, // Original device's public key (for peer/Android)
	}
	peerResponseJSON, _ := json.Marshal(peerResponse)
	if err := conn.WriteMessage(websocket.TextMessage, peerResponseJSON); err != nil {
		log.Printf("✗ Failed to send to peer: %v", err)
	}

	// Give client time to process the message before closing
	time.Sleep(500 * time.Millisecond)

	// Send success response to originator (Mac) if waiting
	pairingWaitersMu.Lock()
	log.Printf("→ Current waiters: %d", len(pairingWaiters))
	originatorConn := pairingWaiters[token]
	if originatorConn != nil {
		log.Printf("✓ Found originator connection, sending success")
		origResponse := map[string]string{
			"status":          "success",
			"original_token":  origToken,
			"original_device": deviceID,
			"peer_device":     peerInfo.DeviceID,
			"peer_pub":        peerInfo.PublicKey, // Peer's public key (for original/Mac)
		}
		origResponseJSON, _ := json.Marshal(origResponse)
		if err := originatorConn.WriteMessage(websocket.TextMessage, origResponseJSON); err != nil {
			log.Printf("✗ Failed to send to originator: %v", err)
		} else {
			log.Printf("✓ Sent success to originator (Mac)")
		}
		originatorConn.Close()
		delete(pairingWaiters, token)
	} else {
		log.Printf("✗ No originator connection found for token: %s", token)
	}
	pairingWaitersMu.Unlock()

	log.Printf("✓ Pairing completed successfully: %s <-> %s", deviceID, peerInfo.DeviceID)

	// Send close frame to peer gracefully
	conn.WriteMessage(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, "Pairing complete"))
	conn.Close()
}

// getClientIP extracts the client IP from the request
func getClientIP(r *http.Request) string {
	// Do not trust forwarded-IP headers unless a trusted reverse proxy has
	// stripped client-supplied values first; this server has no proxy config.
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}
