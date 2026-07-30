package store

import (
	"os"
	"testing"

	"github.com/google/uuid"
)

// This is an opt-in integration test because it deliberately talks to a real
// Redis instance. Run with CLIPSHARE_REDIS_URL=localhost:6388.
func TestRedisQueuePersistsUntilAcknowledged(t *testing.T) {
	address := os.Getenv("CLIPSHARE_REDIS_URL")
	if address == "" {
		t.Skip("set CLIPSHARE_REDIS_URL to run Redis integration tests")
	}

	redisStore, err := NewRedis(address)
	if err != nil {
		t.Fatalf("connect Redis: %v", err)
	}
	defer redisStore.Close()

	deviceID := "test-device-" + uuid.NewString()
	messageID := uuid.NewString()
	payload := []byte(`{"id":"` + messageID + `","type":"route"}`)

	if err := redisStore.EnqueueMessage(deviceID, messageID, payload); err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	// Replays from a local outbox must not create duplicate queue entries.
	if err := redisStore.EnqueueMessage(deviceID, messageID, payload); err != nil {
		t.Fatalf("deduplicated enqueue: %v", err)
	}

	pending, err := redisStore.PendingMessages(deviceID)
	if err != nil {
		t.Fatalf("read pending: %v", err)
	}
	if len(pending) != 1 || pending[0] != string(payload) {
		t.Fatalf("unexpected durable queue contents: %#v", pending)
	}

	if err := redisStore.AcknowledgeMessage(deviceID, messageID); err != nil {
		t.Fatalf("acknowledge: %v", err)
	}
	pending, err = redisStore.PendingMessages(deviceID)
	if err != nil {
		t.Fatalf("read queue after ack: %v", err)
	}
	if len(pending) != 0 {
		t.Fatalf("message was not removed after ACK: %#v", pending)
	}
}
