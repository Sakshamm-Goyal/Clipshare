package integration

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/clipshare/backend/internal/auth"
	"github.com/clipshare/backend/internal/pairing"
	"github.com/clipshare/backend/internal/store"
	"github.com/clipshare/backend/internal/ws"
	"github.com/gorilla/websocket"
)

// Run with CLIPSHARE_DATABASE_URL and CLIPSHARE_REDIS_URL. This exercises the
// actual PostgreSQL, Redis, HTTP pairing, authenticated WebSocket route, and
// ACK removal path rather than a mock transport.
func TestPairRouteAndAcknowledgeEndToEnd(t *testing.T) {
	databaseURL, redisURL := os.Getenv("CLIPSHARE_DATABASE_URL"), os.Getenv("CLIPSHARE_REDIS_URL")
	if databaseURL == "" || redisURL == "" {
		t.Skip("set CLIPSHARE_DATABASE_URL and CLIPSHARE_REDIS_URL for end-to-end integration")
	}

	db, err := store.NewPostgres(databaseURL)
	if err != nil {
		t.Fatalf("connect Postgres: %v", err)
	}
	defer db.Close()
	if err := db.Migrate(); err != nil {
		t.Fatalf("migrate Postgres: %v", err)
	}

	redisStore, err := store.NewRedis(redisURL)
	if err != nil {
		t.Fatalf("connect Redis: %v", err)
	}
	defer redisStore.Close()

	authService := auth.NewService(db, []byte("integration-secret-at-least-32-characters-long"))
	pairingService := pairing.NewService(db, redisStore, authService)
	hub := ws.NewHub(db, redisStore)
	go hub.Run()

	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/pair/start", pairingService.StartPairing)
	mux.HandleFunc("GET /pair", func(w http.ResponseWriter, r *http.Request) { ws.ServePairingWS(hub, pairingService, w, r) })
	mux.HandleFunc("GET /ws", func(w http.ResponseWriter, r *http.Request) { ws.ServeDeviceWS(hub, authService, w, r) })
	server := httptest.NewServer(mux)
	defer server.Close()
	wsBase := "ws" + strings.TrimPrefix(server.URL, "http")

	macID := "mac-integration-" + time.Now().UTC().Format("20060102150405.000000000")
	androidID := "android-integration-" + time.Now().UTC().Format("20060102150405.000000000")
	macPublicKey := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
	androidPublicKey := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{2}, 32))

	startBody, _ := json.Marshal(map[string]string{
		"device_id": macID, "device_name": "Integration Mac", "public_key": macPublicKey, "platform": "macos",
	})
	response, err := http.Post(server.URL+"/v1/pair/start", "application/json", bytes.NewReader(startBody))
	if err != nil {
		t.Fatalf("start pairing: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("start pairing status: %d", response.StatusCode)
	}
	var pairingStart struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(response.Body).Decode(&pairingStart); err != nil {
		t.Fatalf("decode start response: %v", err)
	}

	originator, _, err := websocket.DefaultDialer.Dial(wsBase+"/pair?token="+pairingStart.Token+"&role=originator", nil)
	if err != nil {
		t.Fatalf("connect originator pairing socket: %v", err)
	}
	defer originator.Close()
	peer, _, err := websocket.DefaultDialer.Dial(wsBase+"/pair?token="+pairingStart.Token+"&role=peer", nil)
	if err != nil {
		t.Fatalf("connect peer pairing socket: %v", err)
	}
	defer peer.Close()
	if err := peer.WriteJSON(map[string]string{
		"device_id": androidID, "device_name": "Integration Android", "public_key": androidPublicKey, "platform": "android",
	}); err != nil {
		t.Fatalf("send peer pairing info: %v", err)
	}

	peer.SetReadDeadline(time.Now().Add(5 * time.Second))
	var peerPairing map[string]string
	if err := peer.ReadJSON(&peerPairing); err != nil {
		t.Fatalf("read peer pairing result: %v", err)
	}
	originator.SetReadDeadline(time.Now().Add(5 * time.Second))
	var originatorPairing map[string]string
	if err := originator.ReadJSON(&originatorPairing); err != nil {
		t.Fatalf("read originator pairing result: %v", err)
	}
	if peerPairing["status"] != "success" || originatorPairing["status"] != "success" {
		t.Fatalf("pairing did not complete: peer=%v originator=%v", peerPairing, originatorPairing)
	}

	macSocket := dialDevice(t, wsBase, originatorPairing["original_token"])
	defer macSocket.Close()
	androidSocket := dialDevice(t, wsBase, peerPairing["peer_token"])
	defer androidSocket.Close()

	routeID := "route-" + time.Now().UTC().Format("150405.000000000")
	if err := androidSocket.WriteJSON(map[string]string{
		"id": routeID, "type": "route", "to": macID, "data": "opaque-encrypted-envelope", "qos": "at-least-once",
	}); err != nil {
		t.Fatalf("send route: %v", err)
	}

	macSocket.SetReadDeadline(time.Now().Add(5 * time.Second))
	var routed ws.Message
	if err := macSocket.ReadJSON(&routed); err != nil {
		t.Fatalf("receive route: %v", err)
	}
	if routed.ID != routeID || routed.From != androidID || routed.To != macID || routed.Data != "opaque-encrypted-envelope" {
		t.Fatalf("route mutated or misdirected: %+v", routed)
	}

	if err := macSocket.WriteJSON(map[string]string{
		"id": routeID, "type": "ack", "to": androidID, "status": "ok",
	}); err != nil {
		t.Fatalf("send ACK: %v", err)
	}
	androidSocket.SetReadDeadline(time.Now().Add(5 * time.Second))
	var acknowledgement ws.Message
	if err := androidSocket.ReadJSON(&acknowledgement); err != nil {
		t.Fatalf("receive ACK: %v", err)
	}
	if acknowledgement.Type != "ack" || acknowledgement.ID != routeID || acknowledgement.From != macID {
		t.Fatalf("unexpected ACK: %+v", acknowledgement)
	}

	pending, err := redisStore.PendingMessages(macID)
	if err != nil {
		t.Fatalf("read durable queue after ACK: %v", err)
	}
	if len(pending) != 0 {
		t.Fatalf("route remained durable after ACK: %v", pending)
	}
}

func dialDevice(t *testing.T, wsBase, token string) *websocket.Conn {
	t.Helper()
	header := http.Header{"Authorization": []string{"Bearer " + token}}
	conn, response, err := websocket.DefaultDialer.Dial(wsBase+"/ws", header)
	if err != nil {
		if response != nil {
			t.Fatalf("connect device socket: %v (HTTP %d)", err, response.StatusCode)
		}
		t.Fatalf("connect device socket: %v", err)
	}
	return conn
}
