package ws

import (
	"encoding/json"
	"log"
	"time"

	"github.com/gorilla/websocket"
)

const (
	// Time allowed to write a message to the peer
	writeWait = 10 * time.Second

	// Time allowed to read the next pong message from the peer
	pongWait = 60 * time.Second

	// Send pings to peer with this period (must be less than pongWait)
	pingPeriod = (pongWait * 9) / 10

	// Maximum encrypted route size. A 5 MiB image grows to roughly 6.7 MiB in
	// base64, plus its AEAD tag and JSON envelope.
	maxMessageSize = 8 * 1024 * 1024
)

// Client represents a WebSocket connection for a device
type Client struct {
	hub      *Hub
	conn     *websocket.Conn
	send     chan []byte
	deviceID string
	userID   string
}

// readPump pumps messages from the WebSocket connection to the hub
func (c *Client) readPump() {
	defer func() {
		c.hub.unregister <- c
		c.conn.Close()
	}()

	c.conn.SetReadLimit(maxMessageSize)
	c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})

	for {
		_, messageBytes, err := c.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("WebSocket error: %v", err)
			}
			break
		}

		// Parse message
		var msg Message
		if err := json.Unmarshal(messageBytes, &msg); err != nil {
			log.Printf("Invalid message format from %s: %v", c.deviceID, err)
			continue
		}

		// Set sender
		msg.From = c.deviceID

		if msg.Type == "ack" {
			if msg.ID == "" || msg.To == "" {
				log.Printf("Invalid acknowledgement from %s", c.deviceID)
				continue
			}
			if msg.To == c.deviceID {
				log.Printf("Invalid acknowledgement from %s to itself", c.deviceID)
				continue
			}
			ackSender, err := c.hub.db.GetDevice(msg.To)
			if err != nil || ackSender == nil || ackSender.UserID != c.userID {
				log.Printf("Unauthorized acknowledgement from %s to %s", c.deviceID, msg.To)
				continue
			}
			msg.Status = "ok"
			c.hub.handleAck(&msg)
			continue
		}

		// Validate routes. The server does not inspect encrypted payloads, but a
		// stable message ID is required for durable at-least-once delivery.
		if msg.Type != "route" || msg.ID == "" || msg.To == "" || msg.Data == "" {
			log.Printf("Invalid message from %s: expected route with id, recipient, and data", c.deviceID)
			continue
		}

		// Ensure sender and receiver are in the same user group
		recipientDevice, err := c.hub.db.GetDevice(msg.To)
		if err != nil || recipientDevice == nil {
			log.Printf("Recipient device not found: %s", msg.To)
			continue
		}

		if recipientDevice.UserID != c.userID {
			log.Printf("Unauthorized: %s attempted to send to %s (different users)", c.deviceID, msg.To)
			continue
		}

		// Route message through hub
		c.hub.broadcast <- &msg
	}
}

// writePump pumps messages from the hub to the WebSocket connection
func (c *Client) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		c.conn.Close()
	}()

	for {
		select {
		case message, ok := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				// Hub closed the channel
				c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}

			// Send messages individually - batching with newlines creates invalid JSON
			if err := c.conn.WriteMessage(websocket.TextMessage, message); err != nil {
				return
			}

			// Send any queued messages individually
			n := len(c.send)
			for i := 0; i < n; i++ {
				c.conn.SetWriteDeadline(time.Now().Add(writeWait))
				if err := c.conn.WriteMessage(websocket.TextMessage, <-c.send); err != nil {
					return
				}
			}

		case <-ticker.C:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}
