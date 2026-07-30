package ws

import (
	"encoding/json"
	"fmt"
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
	queue QueueStore
}

// QueueStore is the durable delivery boundary for the relay. A route remains
// queued until its intended recipient acknowledges the message ID.
type QueueStore interface {
	SetDeviceOnline(deviceID string) error
	RemoveDeviceOnline(deviceID string) error
	EnqueueMessage(deviceID, messageID string, message []byte) error
	PendingMessages(deviceID string) ([]string, error)
	AcknowledgeMessage(deviceID, messageID string) error
}

// Message represents a routed message between devices
type Message struct {
	ID     string `json:"id,omitempty"`
	Type   string `json:"type"` // "route", "ack", "nack"
	From   string `json:"from"`
	To     string `json:"to"`
	Data   string `json:"data"` // base64 encrypted envelope
	QoS    string `json:"qos,omitempty"`
	Status string `json:"status,omitempty"`
}

func NewHub(db *store.Postgres, redis *store.Redis) *Hub {
	return NewHubWithQueue(db, redis)
}

func NewHubWithQueue(db *store.Postgres, queue QueueStore) *Hub {
	return &Hub{
		clients:    make(map[string]*Client),
		register:   make(chan *Client),
		unregister: make(chan *Client),
		broadcast:  make(chan *Message, 256),
		db:         db,
		queue:      queue,
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
			if h.queue != nil {
				if err := h.queue.SetDeviceOnline(client.deviceID); err != nil {
					log.Printf("Failed to mark device online: %v", err)
				}
			}
			log.Printf("Device connected: %s (total: %d)", client.deviceID, len(h.clients))

			// Deliver queued messages
			go h.deliverQueuedMessages(client)

		case client := <-h.unregister:
			h.mu.Lock()
			if current, ok := h.clients[client.deviceID]; ok && current == client {
				delete(h.clients, client.deviceID)
				close(client.send)
			}
			h.mu.Unlock()

			// Mark device as offline
			if h.queue != nil {
				if err := h.queue.RemoveDeviceOnline(client.deviceID); err != nil {
					log.Printf("Failed to mark device offline: %v", err)
				}
			}
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
	messageJSON, err := json.Marshal(msg)
	if err != nil {
		log.Printf("Failed to marshal message: %v", err)
		return
	}

	// Persist before attempting network delivery. A successful WebSocket write is
	// not proof that the peer processed the item.
	if err := h.queueMessage(msg, messageJSON); err != nil {
		log.Printf("Failed to queue message for %s: %v", msg.To, err)
		return
	}

	h.mu.RLock()
	client, online := h.clients[msg.To]
	if online {
		select {
		case client.send <- messageJSON:
			log.Printf("Message routed: %s -> %s", msg.From, msg.To)
		default:
			log.Printf("Client send buffer full; retained queued message for %s", msg.To)
		}
	}
	h.mu.RUnlock()
}

func (h *Hub) queueMessage(msg *Message, messageJSON []byte) error {
	if h.queue == nil {
		return fmt.Errorf("queue unavailable")
	}
	return h.queue.EnqueueMessage(msg.To, msg.ID, messageJSON)
}

func (h *Hub) deliverQueuedMessages(client *Client) {
	if h.queue == nil {
		return
	}
	messages, err := h.queue.PendingMessages(client.deviceID)
	if err != nil {
		log.Printf("Failed to dequeue messages for %s: %v", client.deviceID, err)
		return
	}

	if len(messages) == 0 {
		return
	}

	log.Printf("Delivering %d queued messages to %s", len(messages), client.deviceID)
	h.mu.RLock()
	defer h.mu.RUnlock()
	if current, ok := h.clients[client.deviceID]; !ok || current != client {
		return
	}
	for _, msgJSON := range messages {
		select {
		case client.send <- []byte(msgJSON):
			// Delivered
		default:
			// The item remains queued and will be retried on the next reconnect.
			log.Printf("Client buffer full during queue delivery; item remains queued")
			return
		}
	}
}

// handleAck removes a route only after its intended recipient has confirmed
// successful processing. It forwards the acknowledgement to the sender when
// that sender is currently connected so local outboxes can be cleared too.
func (h *Hub) handleAck(ack *Message) {
	if h.queue == nil {
		return
	}
	if err := h.queue.AcknowledgeMessage(ack.From, ack.ID); err != nil {
		log.Printf("Failed to acknowledge message %s for %s: %v", ack.ID, ack.From, err)
		return
	}

	ackJSON, err := json.Marshal(ack)
	if err != nil {
		log.Printf("Failed to marshal acknowledgement: %v", err)
		return
	}

	h.mu.RLock()
	if sender, online := h.clients[ack.To]; online {
		select {
		case sender.send <- ackJSON:
		default:
			log.Printf("Sender buffer full; acknowledgement %s can be recovered by duplicate route", ack.ID)
		}
	}
	h.mu.RUnlock()
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
