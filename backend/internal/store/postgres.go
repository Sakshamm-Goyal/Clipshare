package store

import (
	"database/sql"
	"fmt"
	"time"

	_ "github.com/lib/pq"
)

type Postgres struct {
	db *sql.DB
}

type Device struct {
	ID        string
	UserID    string
	Name      string
	PublicKey string
	Platform  string
	CreatedAt time.Time
	LastSeen  time.Time
}

type User struct {
	ID        string
	CreatedAt time.Time
}

func NewPostgres(connURL string) (*Postgres, error) {
	db, err := sql.Open("postgres", connURL)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}

	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("ping database: %w", err)
	}

	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)

	return &Postgres{db: db}, nil
}

func (p *Postgres) Close() error {
	return p.db.Close()
}

func (p *Postgres) Migrate() error {
	migrations := []string{
		`CREATE TABLE IF NOT EXISTS users (
			id TEXT PRIMARY KEY,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE TABLE IF NOT EXISTS devices (
			id TEXT PRIMARY KEY,
			user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
			name TEXT NOT NULL,
			public_key TEXT NOT NULL,
			platform TEXT NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			last_seen TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_devices_user_id ON devices(user_id)`,
		`CREATE TABLE IF NOT EXISTS pair_tokens (
			token TEXT PRIMARY KEY,
			device_id TEXT NOT NULL,
			device_pub TEXT NOT NULL,
			expires_at TIMESTAMPTZ NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_pair_tokens_expires ON pair_tokens(expires_at)`,
	}

	for _, migration := range migrations {
		if _, err := p.db.Exec(migration); err != nil {
			return fmt.Errorf("run migration: %w", err)
		}
	}

	return nil
}

func (p *Postgres) CreateUser(id string) error {
	_, err := p.db.Exec("INSERT INTO users (id) VALUES ($1) ON CONFLICT (id) DO NOTHING", id)
	return err
}

func (p *Postgres) CreateDevice(device *Device) error {
	_, err := p.db.Exec(`
		INSERT INTO devices (id, user_id, name, public_key, platform, created_at, last_seen)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (id) DO UPDATE SET
			user_id = EXCLUDED.user_id,
			name = EXCLUDED.name,
			public_key = EXCLUDED.public_key,
			platform = EXCLUDED.platform,
			last_seen = EXCLUDED.last_seen`,
		device.ID, device.UserID, device.Name, device.PublicKey, device.Platform,
		device.CreatedAt, device.LastSeen,
	)
	return err
}

func (p *Postgres) GetDevice(id string) (*Device, error) {
	device := &Device{}
	err := p.db.QueryRow(`
		SELECT id, user_id, name, public_key, platform, created_at, last_seen
		FROM devices WHERE id = $1`,
		id,
	).Scan(&device.ID, &device.UserID, &device.Name, &device.PublicKey,
		&device.Platform, &device.CreatedAt, &device.LastSeen)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return device, nil
}

func (p *Postgres) UpdateDeviceLastSeen(id string) error {
	_, err := p.db.Exec("UPDATE devices SET last_seen = NOW() WHERE id = $1", id)
	return err
}

func (p *Postgres) GetUserDevices(userID string) ([]*Device, error) {
	rows, err := p.db.Query(`
		SELECT id, user_id, name, public_key, platform, created_at, last_seen
		FROM devices WHERE user_id = $1 ORDER BY last_seen DESC`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var devices []*Device
	for rows.Next() {
		device := &Device{}
		if err := rows.Scan(&device.ID, &device.UserID, &device.Name, &device.PublicKey,
			&device.Platform, &device.CreatedAt, &device.LastSeen); err != nil {
			return nil, err
		}
		devices = append(devices, device)
	}

	return devices, rows.Err()
}

func (p *Postgres) CreatePairToken(token, deviceID, devicePub string, expiresAt time.Time) error {
	_, err := p.db.Exec(`
		INSERT INTO pair_tokens (token, device_id, device_pub, expires_at)
		VALUES ($1, $2, $3, $4)`,
		token, deviceID, devicePub, expiresAt,
	)
	return err
}

func (p *Postgres) GetPairToken(token string) (deviceID, devicePub string, err error) {
	var expiresAt time.Time
	err = p.db.QueryRow(`
		SELECT device_id, device_pub, expires_at
		FROM pair_tokens WHERE token = $1`,
		token,
	).Scan(&deviceID, &devicePub, &expiresAt)

	if err == sql.ErrNoRows {
		return "", "", fmt.Errorf("token not found")
	}
	if err != nil {
		return "", "", err
	}

	if time.Now().After(expiresAt) {
		return "", "", fmt.Errorf("token expired")
	}

	return deviceID, devicePub, nil
}

func (p *Postgres) DeletePairToken(token string) error {
	_, err := p.db.Exec("DELETE FROM pair_tokens WHERE token = $1", token)
	return err
}
