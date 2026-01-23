package auth

import (
	"fmt"
	"time"

	"github.com/clipshare/backend/internal/store"
	"github.com/golang-jwt/jwt/v5"
)

type Service struct {
	store     *store.Postgres
	jwtSecret []byte
}

type Claims struct {
	DeviceID string `json:"device_id"`
	UserID   string `json:"user_id"`
	Platform string `json:"platform"`
	jwt.RegisteredClaims
}

func NewService(store *store.Postgres, jwtSecret []byte) *Service {
	return &Service{
		store:     store,
		jwtSecret: jwtSecret,
	}
}

// GenerateDeviceToken creates a JWT for device authentication
func (s *Service) GenerateDeviceToken(deviceID, userID, platform string) (string, error) {
	claims := &Claims{
		DeviceID: deviceID,
		UserID:   userID,
		Platform: platform,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(365 * 24 * time.Hour)), // 1 year
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			Issuer:    "clipshare-backend",
		},
	}

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(s.jwtSecret)
}

// ValidateToken validates a JWT and returns the claims
func (s *Service) ValidateToken(tokenString string) (*Claims, error) {
	token, err := jwt.ParseWithClaims(tokenString, &Claims{}, func(token *jwt.Token) (interface{}, error) {
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
		}
		return s.jwtSecret, nil
	})

	if err != nil {
		return nil, fmt.Errorf("parse token: %w", err)
	}

	claims, ok := token.Claims.(*Claims)
	if !ok || !token.Valid {
		return nil, fmt.Errorf("invalid token")
	}

	return claims, nil
}

// ValidateDevice checks if a device exists and is valid
func (s *Service) ValidateDevice(deviceID string) (*store.Device, error) {
	device, err := s.store.GetDevice(deviceID)
	if err != nil {
		return nil, fmt.Errorf("get device: %w", err)
	}
	if device == nil {
		return nil, fmt.Errorf("device not found")
	}
	return device, nil
}
