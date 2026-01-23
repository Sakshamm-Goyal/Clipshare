package ws

import (
	"encoding/json"
	"testing"
)

func TestMessageSerialization(t *testing.T) {
	msg := Message{
		Type: "route",
		From: "device-1",
		To:   "device-2",
		Data: "encrypted-data-base64",
		QoS:  "at-least-once",
	}

	// Serialize
	jsonBytes, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("Failed to marshal message: %v", err)
	}

	// Deserialize
	var parsed Message
	if err := json.Unmarshal(jsonBytes, &parsed); err != nil {
		t.Fatalf("Failed to unmarshal message: %v", err)
	}

	// Verify
	if parsed.Type != msg.Type {
		t.Errorf("Expected type '%s', got '%s'", msg.Type, parsed.Type)
	}
	if parsed.From != msg.From {
		t.Errorf("Expected from '%s', got '%s'", msg.From, parsed.From)
	}
	if parsed.To != msg.To {
		t.Errorf("Expected to '%s', got '%s'", msg.To, parsed.To)
	}
	if parsed.Data != msg.Data {
		t.Errorf("Expected data '%s', got '%s'", msg.Data, parsed.Data)
	}
	if parsed.QoS != msg.QoS {
		t.Errorf("Expected qos '%s', got '%s'", msg.QoS, parsed.QoS)
	}
}

func TestMessageWithoutOptionalFields(t *testing.T) {
	jsonStr := `{"type":"route","from":"a","to":"b","data":"xyz"}`

	var msg Message
	if err := json.Unmarshal([]byte(jsonStr), &msg); err != nil {
		t.Fatalf("Failed to unmarshal: %v", err)
	}

	if msg.QoS != "" {
		t.Errorf("Expected empty QoS, got '%s'", msg.QoS)
	}
}

func TestHubCreation(t *testing.T) {
	// Test hub creation without stores (nil is acceptable for basic tests)
	hub := NewHub(nil, nil)

	if hub == nil {
		t.Fatal("NewHub returned nil")
	}

	if hub.clients == nil {
		t.Error("Hub clients map is nil")
	}

	if hub.register == nil {
		t.Error("Hub register channel is nil")
	}

	if hub.unregister == nil {
		t.Error("Hub unregister channel is nil")
	}

	if hub.broadcast == nil {
		t.Error("Hub broadcast channel is nil")
	}
}

func TestHubIsDeviceOnline(t *testing.T) {
	hub := NewHub(nil, nil)

	// Initially no device should be online
	if hub.IsDeviceOnline("device-1") {
		t.Error("Device should not be online initially")
	}

	// Manually add a client
	hub.clients["device-1"] = &Client{deviceID: "device-1"}

	if !hub.IsDeviceOnline("device-1") {
		t.Error("Device should be online after adding to clients map")
	}

	// Remove client
	delete(hub.clients, "device-1")

	if hub.IsDeviceOnline("device-1") {
		t.Error("Device should not be online after removal")
	}
}

func TestHubGetClient(t *testing.T) {
	hub := NewHub(nil, nil)

	// Test non-existent client
	client, ok := hub.GetClient("non-existent")
	if ok {
		t.Error("Should not find non-existent client")
	}
	if client != nil {
		t.Error("Client should be nil for non-existent device")
	}

	// Add a client
	testClient := &Client{deviceID: "test-device", userID: "test-user"}
	hub.clients["test-device"] = testClient

	// Test existing client
	client, ok = hub.GetClient("test-device")
	if !ok {
		t.Error("Should find existing client")
	}
	if client == nil {
		t.Error("Client should not be nil")
	}
	if client.deviceID != "test-device" {
		t.Errorf("Expected device ID 'test-device', got '%s'", client.deviceID)
	}
}
