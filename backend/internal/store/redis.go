package store

import (
	"context"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

type Redis struct {
	client *redis.Client
	ctx    context.Context
}

func NewRedis(addr string) (*Redis, error) {
	client := redis.NewClient(&redis.Options{
		Addr:         addr,
		DialTimeout:  5 * time.Second,
		ReadTimeout:  3 * time.Second,
		WriteTimeout: 3 * time.Second,
		PoolSize:     10,
	})

	ctx := context.Background()
	if err := client.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("ping redis: %w", err)
	}

	return &Redis{client: client, ctx: ctx}, nil
}

func (r *Redis) Close() error {
	return r.client.Close()
}

// SetDeviceOnline marks a device as online
func (r *Redis) SetDeviceOnline(deviceID string) error {
	return r.client.Set(r.ctx, fmt.Sprintf("device:online:%s", deviceID), "1", 70*time.Second).Err()
}

// IsDeviceOnline checks if a device is online
func (r *Redis) IsDeviceOnline(deviceID string) (bool, error) {
	val, err := r.client.Get(r.ctx, fmt.Sprintf("device:online:%s", deviceID)).Result()
	if err == redis.Nil {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return val == "1", nil
}

// RemoveDeviceOnline marks a device as offline
func (r *Redis) RemoveDeviceOnline(deviceID string) error {
	return r.client.Del(r.ctx, fmt.Sprintf("device:online:%s", deviceID)).Err()
}

// EnqueueMessage persists one encrypted route until its recipient ACKs it.
// The Lua script makes the ID de-duplication and list insertion atomic.
func (r *Redis) EnqueueMessage(deviceID, messageID string, message []byte) error {
	queueKey := fmt.Sprintf("device:queue:%s", deviceID)
	indexKey := fmt.Sprintf("device:queue:index:%s", deviceID)

	const enqueueScript = `
if redis.call('HEXISTS', KEYS[2], ARGV[1]) == 1 then return 0 end
redis.call('RPUSH', KEYS[1], ARGV[2])
redis.call('HSET', KEYS[2], ARGV[1], ARGV[2])
redis.call('EXPIRE', KEYS[1], 86400)
redis.call('EXPIRE', KEYS[2], 86400)
return 1`

	return r.client.Eval(r.ctx, enqueueScript, []string{queueKey, indexKey}, messageID, string(message)).Err()
}

// PendingMessages returns durable routes without removing them. A connection
// drop after delivery is therefore safe: the same message is retried until an
// ACK removes it.
func (r *Redis) PendingMessages(deviceID string) ([]string, error) {
	return r.client.LRange(r.ctx, fmt.Sprintf("device:queue:%s", deviceID), 0, -1).Result()
}

// AcknowledgeMessage removes the exact queued route for a recipient and ID.
func (r *Redis) AcknowledgeMessage(deviceID, messageID string) error {
	queueKey := fmt.Sprintf("device:queue:%s", deviceID)
	indexKey := fmt.Sprintf("device:queue:index:%s", deviceID)

	const acknowledgeScript = `
local message = redis.call('HGET', KEYS[2], ARGV[1])
if not message then return 0 end
redis.call('LREM', KEYS[1], 0, message)
redis.call('HDEL', KEYS[2], ARGV[1])
if redis.call('HLEN', KEYS[2]) == 0 then
  redis.call('DEL', KEYS[1])
  redis.call('DEL', KEYS[2])
end
return 1`

	return r.client.Eval(r.ctx, acknowledgeScript, []string{queueKey, indexKey}, messageID).Err()
}

// StorePairingSession stores temporary pairing session data
func (r *Redis) StorePairingSession(token string, data string, ttl time.Duration) error {
	return r.client.Set(r.ctx, fmt.Sprintf("pair:session:%s", token), data, ttl).Err()
}

// GetPairingSession retrieves pairing session data
func (r *Redis) GetPairingSession(token string) (string, error) {
	return r.client.Get(r.ctx, fmt.Sprintf("pair:session:%s", token)).Result()
}

// DeletePairingSession removes pairing session
func (r *Redis) DeletePairingSession(token string) error {
	return r.client.Del(r.ctx, fmt.Sprintf("pair:session:%s", token)).Err()
}
