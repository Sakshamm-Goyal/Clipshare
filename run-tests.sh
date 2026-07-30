#!/bin/bash

# Universal Clipboard Sync - Automated Test Setup
# This script sets up the test environment and guides you through testing

set -e  # Exit on error

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Universal Clipboard Sync - Test Environment Setup      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to print colored messages
print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "ℹ️  $1"
}

# Check prerequisites
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Checking Prerequisites"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check Docker
if ! command -v docker &> /dev/null; then
    print_error "Docker not found. Please install Docker Desktop."
    exit 1
fi
print_success "Docker installed"

# Check if Docker is running
if ! docker info &> /dev/null; then
    print_warning "Docker daemon not running. Please start Docker Desktop."
    echo ""
    echo "On macOS: Open Docker Desktop application"
    echo "Waiting for Docker to start..."

    # Wait for Docker to start (max 60 seconds)
    for i in {1..12}; do
        if docker info &> /dev/null; then
            print_success "Docker is now running"
            break
        fi
        echo -n "."
        sleep 5
    done

    if ! docker info &> /dev/null; then
        print_error "Docker failed to start. Please start Docker Desktop manually."
        exit 1
    fi
fi
print_success "Docker daemon running"

# Check Go
if ! command -v go &> /dev/null; then
    print_error "Go not found. Please install Go 1.22+"
    echo "Install from: https://go.dev/dl/"
    exit 1
fi
GO_VERSION=$(go version | awk '{print $3}')
print_success "Go installed ($GO_VERSION)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Starting Test Infrastructure"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Start Docker Compose services
print_info "Starting PostgreSQL and Redis containers..."
docker-compose -f docker-compose.test.yml up -d

# Wait for services to be healthy
print_info "Waiting for services to be ready (30 seconds)..."
sleep 10

# Check PostgreSQL
if docker exec clipshare-postgres-test pg_isready -U clipshare &> /dev/null; then
    print_success "PostgreSQL ready on port 5433"
else
    print_error "PostgreSQL not ready"
    exit 1
fi

# Check Redis
if docker exec clipshare-redis-test redis-cli ping &> /dev/null; then
    print_success "Redis ready on port 6388"
else
    print_error "Redis not ready"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3: Preparing Backend Server"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cd backend

# Download dependencies
print_info "Downloading Go dependencies..."
go mod download
print_success "Dependencies ready"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 4: Starting Backend Server"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

print_info "Backend server will start on port 8081"
print_warning "Keep this terminal open during testing!"
echo ""
echo "Configuration:"
echo "  - Server: http://localhost:8081"
echo "  - Database: postgres://localhost:5433/clipshare_test"
echo "  - Redis: localhost:6388"
echo "  - JWT Secret: test-secret-key-for-testing-only"
echo ""

# Create a background script to run the server
cat > /tmp/start-clipshare-server.sh << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
go run cmd/server/main.go \
  -addr=:8081 \
  -db="postgres://clipshare:testpass123@localhost:5433/clipshare_test?sslmode=disable" \
  -redis="localhost:6388" \
  -jwt-secret="test-secret-key-for-testing-only"
EOF

chmod +x /tmp/start-clipshare-server.sh

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
print_success "Test environment is ready!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "NEXT STEPS:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1️⃣  Start the backend server in a NEW TERMINAL:"
echo "    cd backend"
echo "    go run cmd/server/main.go \\"
echo "      -addr=:8081 \\"
echo "      -db=\"postgres://clipshare:testpass123@localhost:5433/clipshare_test?sslmode=disable\" \\"
echo "      -redis=\"localhost:6388\" \\"
echo "      -jwt-secret=\"test-secret-key-for-testing-only\""
echo ""
echo "2️⃣  Verify the server is running:"
echo "    curl http://localhost:8081/healthz"
echo "    (Should return: ok)"
echo ""
echo "3️⃣  Run Playwright MCP tests:"
echo "    See TESTING_GUIDE.md for detailed test instructions"
echo ""
echo "4️⃣  Use Claude Code to execute Playwright MCP tests"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
print_info "Test infrastructure is running. Press Ctrl+C in the server terminal to stop."
print_info "To stop all services: docker-compose -f docker-compose.test.yml down -v"
echo ""
