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

// EnqueueMessage queues a message for offline device
func (r *Redis) EnqueueMessage(deviceID string, message []byte) error {
	key := fmt.Sprintf("device:queue:%s", deviceID)
	// Add to list
	if err := r.client.RPush(r.ctx, key, message).Err(); err != nil {
		return err
	}
	// Set TTL to 24 hours
	return r.client.Expire(r.ctx, key, 24*time.Hour).Err()
}

// DequeueMessages retrieves all queued messages for a device
func (r *Redis) DequeueMessages(deviceID string) ([]string, error) {
	key := fmt.Sprintf("device:queue:%s", deviceID)
	messages, err := r.client.LRange(r.ctx, key, 0, -1).Result()
	if err != nil {
		return nil, err
	}
	// Clear the queue
	if len(messages) > 0 {
		r.client.Del(r.ctx, key)
	}
	return messages, nil
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
