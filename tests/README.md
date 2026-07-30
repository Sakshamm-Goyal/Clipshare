# Universal Clipboard - Test Suite

Comprehensive testing for the clipboard sync system using Playwright MCP.

## Prerequisites

- Docker and Docker Compose
- Go 1.22+
- Node.js (for test runner scripts)
- Playwright MCP server running

## Quick Start

### 1. Start Test Dependencies

```bash
# Start PostgreSQL and Redis in test mode
docker-compose -f docker-compose.test.yml up -d

# Wait for services to be healthy
docker-compose -f docker-compose.test.yml ps
```

### 2. Start Backend Server

```bash
# In one terminal, start the backend in test mode
cd backend
go run cmd/server/main.go \
  -addr=:8081 \
  -db="postgres://clipshare:testpass123@localhost:5433/clipshare_test?sslmode=disable" \
  -redis="localhost:6388" \
  -jwt-secret="test-secret-key-for-testing-only-not-production"
```

### 3. Run Tests

```bash
# In another terminal
cd tests
npm test              # Run all tests
npm run test:api      # API tests only
npm run test:ws       # WebSocket tests only
npm run test:e2e      # End-to-end tests only
```

## Test Structure

```
tests/
├── api/              # REST API endpoint tests
│   ├── health.test.js
│   └── pairing.test.js
├── websocket/        # WebSocket functionality tests
│   ├── connection.test.js
│   └── messaging.test.js
├── e2e/              # End-to-end integration tests
│   └── full-sync.test.js
├── helpers/          # Test utilities
│   └── crypto.js
└── test-runner.js    # Main test orchestrator
```

## Test Coverage

### API Tests
- ✅ Health check endpoint
- ✅ Pairing flow initiation
- ✅ QR code generation
- ✅ Token validation

### WebSocket Tests
- ✅ Connection establishment
- ✅ JWT authentication
- ✅ Message routing
- ✅ Reconnection handling

### E2E Tests
- ✅ Complete pairing flow
- ✅ Bi-directional message sync
- ✅ Encryption/decryption
- ✅ Offline queue

## Cleanup

```bash
# Stop and remove test containers
docker-compose -f docker-compose.test.yml down -v
```

## Troubleshooting

**Backend won't start:**
- Check PostgreSQL is running: `docker-compose -f docker-compose.test.yml ps`
- Check ports are available: `lsof -i :8081 -i :5433 -i :6388`

**Tests fail to connect:**
- Verify backend is running: `curl http://localhost:8081/healthz`
- Check logs: `docker-compose -f docker-compose.test.yml logs`

**Database issues:**
- Reset database: `docker-compose -f docker-compose.test.yml down -v && docker-compose -f docker-compose.test.yml up -d`
