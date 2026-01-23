package ws

import (
	"encoding/json"
	"log"
	"sync"
	"time"

	"github.com/clipshare/backend/internal/store"
)

// Hub manages active WebSocket connections
type Hub struct {
	// Registered clients (device_id -> *Client)
	clients map[string]*Client
	mu      sync.RWMutex

	// Register requests from clients
	register chan *Client

	// Unregister requests from clients
	unregister chan *Client

	// Inbound messages from clients
	broadcast chan *Message

	// Store
	db    *store.Postgres
	redis *store.Redis
}

// Message represents a routed message between devices
type Message struct {
	Type string `json:"type"` // "route", "ack", "nack"
	From string `json:"from"`
	To   string `json:"to"`
	Data string `json:"data"` // base64 encrypted envelope
	QoS  string `json:"qos,omitempty"`
}

func NewHub(db *store.Postgres, redis *store.Redis) *Hub {
	return &Hub{
		clients:    make(map[string]*Client),
		register:   make(chan *Client),
		unregister: make(chan *Client),
		broadcast:  make(chan *Message, 256),
		db:         db,
		redis:      redis,
	}
}

func (h *Hub) Run() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case client := <-h.register:
			h.mu.Lock()
			h.clients[client.deviceID] = client
			h.mu.Unlock()

			// Mark device as online
			h.redis.SetDeviceOnline(client.deviceID)
			log.Printf("Device connected: %s (total: %d)", client.deviceID, len(h.clients))

			// Deliver queued messages
			go h.deliverQueuedMessages(client)

		case client := <-h.unregister:
			h.mu.Lock()
			if _, ok := h.clients[client.deviceID]; ok {
				delete(h.clients, client.deviceID)
				close(client.send)
			}
			h.mu.Unlock()

			// Mark device as offline
			h.redis.RemoveDeviceOnline(client.deviceID)
			log.Printf("Device disconnected: %s (total: %d)", client.deviceID, len(h.clients))

		case message := <-h.broadcast:
			h.routeMessage(message)

		case <-ticker.C:
			// Periodic cleanup or health checks
			h.mu.RLock()
			count := len(h.clients)
			h.mu.RUnlock()
			log.Printf("Active connections: %d", count)
		}
	}
}

func (h *Hub) routeMessage(msg *Message) {
	// Check if recipient is online
	h.mu.RLock()
	client, online := h.clients[msg.To]
	h.mu.RUnlock()

	if online {
		// Deliver immediately
		messageJSON, err := json.Marshal(msg)
		if err != nil {
			log.Printf("Failed to marshal message: %v", err)
			return
		}

		select {
		case client.send <- messageJSON:
			log.Printf("Message routed: %s -> %s", msg.From, msg.To)
		default:
			log.Printf("Client send buffer full, queueing message: %s", msg.To)
			h.queueMessage(msg)
		}
	} else {
		// Queue for later delivery
		log.Printf("Recipient offline, queueing: %s -> %s", msg.From, msg.To)
		h.queueMessage(msg)
	}
}

func (h *Hub) queueMessage(msg *Message) {
	messageJSON, err := json.Marshal(msg)
	if err != nil {
		log.Printf("Failed to marshal message for queue: %v", err)
		return
	}

	if err := h.redis.EnqueueMessage(msg.To, messageJSON); err != nil {
		log.Printf("Failed to queue message: %v", err)
	}
}

func (h *Hub) deliverQueuedMessages(client *Client) {
	messages, err := h.redis.DequeueMessages(client.deviceID)
	if err != nil {
		log.Printf("Failed to dequeue messages for %s: %v", client.deviceID, err)
		return
	}

	if len(messages) == 0 {
		return
	}

	log.Printf("Delivering %d queued messages to %s", len(messages), client.deviceID)
	for _, msgJSON := range messages {
		select {
		case client.send <- []byte(msgJSON):
			// Delivered
		default:
			// Buffer full, re-queue
			log.Printf("Client buffer full during queue delivery, re-queueing")
			h.redis.EnqueueMessage(client.deviceID, []byte(msgJSON))
			return
		}
	}
}

// GetClient returns a client by device ID
func (h *Hub) GetClient(deviceID string) (*Client, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	client, ok := h.clients[deviceID]
	return client, ok
}

// IsDeviceOnline checks if a device is currently connected
func (h *Hub) IsDeviceOnline(deviceID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	_, ok := h.clients[deviceID]
	return ok
}
