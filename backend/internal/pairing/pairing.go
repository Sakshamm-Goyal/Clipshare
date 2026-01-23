package pairing

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/clipshare/backend/internal/auth"
	"github.com/clipshare/backend/internal/store"
	"github.com/google/uuid"
)

// getLocalIP returns the local IP address of the machine
func getLocalIP() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ""
	}
	for _, addr := range addrs {
		if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() {
			if ipnet.IP.To4() != nil {
				return ipnet.IP.String()
			}
		}
	}
	return ""
}

type Service struct {
	db    *store.Postgres
	redis *store.Redis
	auth  *auth.Service
}

type StartPairingRequest struct {
	DeviceID   string `json:"device_id"`
	DeviceName string `json:"device_name"`
	PublicKey  string `json:"public_key"`
	Platform   string `json:"platform"`
}

type StartPairingResponse struct {
	Token      string    `json:"token"`
	ServerURL  string    `json:"server_url"`
	ExpiresAt  time.Time `json:"expires_at"`
	DeviceID   string    `json:"device_id"`
	DevicePub  string    `json:"device_pub"`
}

type CompletePairingRequest struct {
	Token            string `json:"token"`
	PeerDeviceID     string `json:"peer_device_id"`
	PeerDeviceName   string `json:"peer_device_name"`
	PeerPublicKey    string `json:"peer_public_key"`
	PeerPlatform     string `json:"peer_platform"`
	SharedSecretHash string `json:"shared_secret_hash"` // For verification
}

func NewService(db *store.Postgres, redis *store.Redis, auth *auth.Service) *Service {
	return &Service{db: db, redis: redis, auth: auth}
}

// StartPairing creates a pairing token (called by the first device, typically Mac)
func (s *Service) StartPairing(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req StartPairingRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	// Validate inputs
	if req.DeviceID == "" || req.PublicKey == "" || req.Platform == "" {
		http.Error(w, "Missing required fields", http.StatusBadRequest)
		return
	}

	// Generate pairing token
	tokenBytes := make([]byte, 16)
	if _, err := rand.Read(tokenBytes); err != nil {
		http.Error(w, "Failed to generate token", http.StatusInternalServerError)
		return
	}
	token := base64.URLEncoding.EncodeToString(tokenBytes)

	// Store token in database (10 minute expiry)
	expiresAt := time.Now().Add(10 * time.Minute)
	if err := s.db.CreatePairToken(token, req.DeviceID, req.PublicKey, expiresAt); err != nil {
		http.Error(w, "Failed to create pairing token", http.StatusInternalServerError)
		return
	}

	// Store session data in Redis
	sessionData := map[string]string{
		"device_id":   req.DeviceID,
		"device_name": req.DeviceName,
		"public_key":  req.PublicKey,
		"platform":    req.Platform,
	}
	sessionJSON, _ := json.Marshal(sessionData)
	if err := s.redis.StorePairingSession(token, string(sessionJSON), 10*time.Minute); err != nil {
		http.Error(w, "Failed to store session", http.StatusInternalServerError)
		return
	}

	// Determine server URL for the QR code
	// Use SERVER_URL env var if set, otherwise derive from request
	serverURL := os.Getenv("SERVER_URL")
	if serverURL == "" {
		host := r.Host
		// If host is localhost, replace with actual local IP for mobile devices
		if strings.HasPrefix(host, "localhost") || strings.HasPrefix(host, "127.0.0.1") {
			localIP := getLocalIP()
			if localIP != "" {
				// Extract port from host if present
				port := "8080"
				if idx := strings.LastIndex(host, ":"); idx != -1 {
					port = host[idx+1:]
				}
				host = localIP + ":" + port
			}
		}
		// Use ws:// for local network (mobile devices on same network)
		serverURL = "ws://" + host + "/pair"
	} else {
		serverURL = serverURL + "/pair"
	}

	// Return pairing info
	response := StartPairingResponse{
		Token:     token,
		ServerURL: serverURL,
		ExpiresAt: expiresAt,
		DeviceID:  req.DeviceID,
		DevicePub: req.PublicKey,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

// CompletePairing finalizes pairing and creates user + devices (called after key exchange)
func (s *Service) CompletePairing(token string, peerDeviceID, peerDeviceName, peerPubKey, peerPlatform string) (string, string, error) {
	// Get original device info from token
	origDeviceID, origDevicePub, err := s.db.GetPairToken(token)
	if err != nil {
		return "", "", fmt.Errorf("invalid or expired token: %w", err)
	}

	// Get session data
	sessionJSON, err := s.redis.GetPairingSession(token)
	if err != nil {
		return "", "", fmt.Errorf("session not found")
	}

	var sessionData map[string]string
	if err := json.Unmarshal([]byte(sessionJSON), &sessionData); err != nil {
		return "", "", fmt.Errorf("invalid session data")
	}

	// Create new user
	userID := uuid.New().String()
	if err := s.db.CreateUser(userID); err != nil {
		return "", "", fmt.Errorf("create user: %w", err)
	}

	// Create both devices
	now := time.Now()

	origDevice := &store.Device{
		ID:        origDeviceID,
		UserID:    userID,
		Name:      sessionData["device_name"],
		PublicKey: origDevicePub,
		Platform:  sessionData["platform"],
		CreatedAt: now,
		LastSeen:  now,
	}

	peerDevice := &store.Device{
		ID:        peerDeviceID,
		UserID:    userID,
		Name:      peerDeviceName,
		PublicKey: peerPubKey,
		Platform:  peerPlatform,
		CreatedAt: now,
		LastSeen:  now,
	}

	if err := s.db.CreateDevice(origDevice); err != nil {
		return "", "", fmt.Errorf("create original device: %w", err)
	}

	if err := s.db.CreateDevice(peerDevice); err != nil {
		return "", "", fmt.Errorf("create peer device: %w", err)
	}

	// Generate JWTs for both devices
	origToken, err := s.auth.GenerateDeviceToken(origDeviceID, userID, sessionData["platform"])
	if err != nil {
		return "", "", fmt.Errorf("generate original device token: %w", err)
	}

	peerToken, err := s.auth.GenerateDeviceToken(peerDeviceID, userID, peerPlatform)
	if err != nil {
		return "", "", fmt.Errorf("generate peer device token: %w", err)
	}

	// Clean up pairing data
	s.db.DeletePairToken(token)
	s.redis.DeletePairingSession(token)

	return origToken, peerToken, nil
}
