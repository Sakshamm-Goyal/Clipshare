package auth

import (
	"testing"
	"time"
)

func TestGenerateAndValidateToken(t *testing.T) {
	// Create service with test secret
	service := &Service{
		jwtSecret: []byte("test-secret-key-12345"),
	}

	// Generate token
	token, err := service.GenerateDeviceToken("device-123", "user-456", "macos")
	if err != nil {
		t.Fatalf("Failed to generate token: %v", err)
	}

	if token == "" {
		t.Fatal("Generated token is empty")
	}

	// Validate token
	claims, err := service.ValidateToken(token)
	if err != nil {
		t.Fatalf("Failed to validate token: %v", err)
	}

	// Check claims
	if claims.DeviceID != "device-123" {
		t.Errorf("Expected device ID 'device-123', got '%s'", claims.DeviceID)
	}

	if claims.UserID != "user-456" {
		t.Errorf("Expected user ID 'user-456', got '%s'", claims.UserID)
	}

	if claims.Platform != "macos" {
		t.Errorf("Expected platform 'macos', got '%s'", claims.Platform)
	}
}

func TestInvalidToken(t *testing.T) {
	service := &Service{
		jwtSecret: []byte("test-secret-key-12345"),
	}

	// Test with invalid token
	_, err := service.ValidateToken("invalid-token")
	if err == nil {
		t.Error("Expected error for invalid token, got nil")
	}

	// Test with empty token
	_, err = service.ValidateToken("")
	if err == nil {
		t.Error("Expected error for empty token, got nil")
	}
}

func TestTokenWithDifferentSecret(t *testing.T) {
	service1 := &Service{
		jwtSecret: []byte("secret-1"),
	}
	service2 := &Service{
		jwtSecret: []byte("secret-2"),
	}

	// Generate token with service1
	token, err := service1.GenerateDeviceToken("device-123", "user-456", "android")
	if err != nil {
		t.Fatalf("Failed to generate token: %v", err)
	}

	// Try to validate with service2 (different secret)
	_, err = service2.ValidateToken(token)
	if err == nil {
		t.Error("Expected error when validating token with different secret")
	}
}

func TestTokenExpiry(t *testing.T) {
	service := &Service{
		jwtSecret: []byte("test-secret"),
	}

	token, err := service.GenerateDeviceToken("device", "user", "macos")
	if err != nil {
		t.Fatalf("Failed to generate token: %v", err)
	}

	claims, err := service.ValidateToken(token)
	if err != nil {
		t.Fatalf("Failed to validate token: %v", err)
	}

	// Check that expiry is approximately 1 year from now
	expectedExpiry := time.Now().Add(365 * 24 * time.Hour)
	actualExpiry := claims.ExpiresAt.Time

	diff := actualExpiry.Sub(expectedExpiry)
	if diff < -time.Minute || diff > time.Minute {
		t.Errorf("Token expiry is not approximately 1 year from now: got %v", actualExpiry)
	}
}
