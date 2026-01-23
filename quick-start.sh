#!/bin/bash

# Universal Clipboard Sync - Quick Start Script
# Automated setup for getting everything running quickly

set -e  # Exit on error

# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Emojis
CHECK="✅"
CROSS="❌"
WARN="⚠️"
INFO="ℹ️"
ROCKET="🚀"
GEAR="⚙️"

# Functions for colored output
print_header() {
    echo -e "\n${PURPLE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║  $1${NC}"
    echo -e "${PURPLE}╚══════════════════════════════════════════════════════════╝${NC}\n"
}

print_success() {
    echo -e "${GREEN}${CHECK} $1${NC}"
}

print_error() {
    echo -e "${RED}${CROSS} $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}${WARN} $1${NC}"
}

print_info() {
    echo -e "${CYAN}${INFO} $1${NC}"
}

print_step() {
    echo -e "\n${BLUE}${GEAR} $1${NC}"
}

# Banner
clear
echo -e "${PURPLE}"
cat << "EOF"
╦ ╦┌┐┌┬┬  ┬┌─┐┬─┐┌─┐┌─┐┬    ┌─┐┬  ┬┌─┐┌┐ ┌─┐┌─┐┬─┐┌┬┐
║ ║││││└┐┌┘├┤ ├┬┘└─┐├─┤│    │  │  │├─┘├┴┐│ │├─┤├┬┘ ││
╚═╝┘└┘┴ └┘ └─┘┴└─└─┘┴ ┴┴─┘  └─┘┴─┘┴┴  └─┘└─┘┴ ┴┴└──┴┘
        Quick Start Setup Script
EOF
echo -e "${NC}"
echo -e "${CYAN}This script will set up everything you need to run${NC}"
echo -e "${CYAN}Universal Clipboard Sync on your system.${NC}"
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_error "Please do not run as root (sudo). Run as normal user."
    exit 1
fi

# Detect OS
print_step "Detecting operating system..."
OS="$(uname -s)"
case "${OS}" in
    Darwin*)    OS_TYPE="macOS";;
    Linux*)     OS_TYPE="Linux";;
    MINGW*)     OS_TYPE="Windows";;
    *)          OS_TYPE="Unknown";;
esac
print_info "Detected: ${OS_TYPE}"

# Check prerequisites
print_header "Checking Prerequisites"

MISSING_DEPS=0

# Check Go
print_step "Checking for Go..."
if command -v go &> /dev/null; then
    GO_VERSION=$(go version | awk '{print $3}')
    print_success "Go is installed (${GO_VERSION})"
else
    print_error "Go is not installed"
    print_info "Install from: https://go.dev/dl/"
    if [ "$OS_TYPE" = "macOS" ]; then
        print_info "Quick install: brew install go"
    fi
    MISSING_DEPS=1
fi

# Check Docker
print_step "Checking for Docker..."
if command -v docker &> /dev/null; then
    if docker info &> /dev/null; then
        DOCKER_VERSION=$(docker --version | awk '{print $3}')
        print_success "Docker is installed and running (${DOCKER_VERSION})"
    else
        print_warning "Docker is installed but not running"
        print_info "Please start Docker Desktop"
        MISSING_DEPS=1
    fi
else
    print_error "Docker is not installed"
    print_info "Install from: https://www.docker.com/products/docker-desktop/"
    MISSING_DEPS=1
fi

# Check curl
print_step "Checking for curl..."
if command -v curl &> /dev/null; then
    print_success "curl is installed"
else
    print_warning "curl is not installed (optional but recommended)"
fi

# Exit if missing critical dependencies
if [ $MISSING_DEPS -eq 1 ]; then
    echo ""
    print_error "Missing required dependencies. Please install them and run again."
    exit 1
fi

echo ""
print_success "All prerequisites are installed!"

# Get project directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="${SCRIPT_DIR}"

print_info "Project directory: ${PROJECT_DIR}"

# Ask user what to set up
print_header "Setup Options"
echo "What would you like to set up?"
echo ""
echo "  1) Everything (Backend + macOS app + instructions for Android)"
echo "  2) Backend Server only"
echo "  3) Backend + macOS app"
echo "  4) Just start existing setup"
echo "  5) Stop everything and cleanup"
echo ""
read -p "Enter choice [1-5]: " SETUP_CHOICE

case $SETUP_CHOICE in
    5)
        print_header "Stopping and Cleaning Up"

        print_step "Stopping backend server..."
        pkill -f "go run cmd/server/main.go" || print_info "Backend not running"

        print_step "Stopping Docker containers..."
        cd "${PROJECT_DIR}"
        docker-compose -f docker-compose.test.yml down -v || print_info "Docker containers not running"

        print_success "Cleanup complete!"
        exit 0
        ;;
    4)
        print_header "Starting Existing Setup"
        SETUP_BACKEND=1
        SETUP_MACOS=0
        SKIP_INSTALL=1
        ;;
    3)
        print_header "Setting Up Backend + macOS App"
        SETUP_BACKEND=1
        SETUP_MACOS=1
        SKIP_INSTALL=0
        ;;
    2)
        print_header "Setting Up Backend Only"
        SETUP_BACKEND=1
        SETUP_MACOS=0
        SKIP_INSTALL=0
        ;;
    *)
        print_header "Setting Up Everything"
        SETUP_BACKEND=1
        SETUP_MACOS=1
        SKIP_INSTALL=0
        ;;
esac

# Setup Backend
if [ $SETUP_BACKEND -eq 1 ]; then
    print_header "Backend Server Setup"

    # Start Docker containers
    print_step "Starting PostgreSQL and Redis containers..."
    cd "${PROJECT_DIR}"
    docker-compose -f docker-compose.test.yml up -d

    print_info "Waiting for containers to be ready (15 seconds)..."
    sleep 5

    # Check PostgreSQL
    if docker exec clipshare-postgres-test pg_isready -U clipshare &> /dev/null; then
        print_success "PostgreSQL is ready"
    else
        print_error "PostgreSQL failed to start"
        exit 1
    fi

    # Check Redis
    if docker exec clipshare-redis-test redis-cli ping &> /dev/null; then
        print_success "Redis is ready"
    else
        print_error "Redis failed to start"
        exit 1
    fi

    # Install dependencies
    if [ $SKIP_INSTALL -eq 0 ]; then
        print_step "Downloading Go dependencies..."
        cd "${PROJECT_DIR}/backend"
        go mod download
        print_success "Dependencies downloaded"
    fi

    # Check if server is already running
    if curl -s http://localhost:8080/healthz &> /dev/null; then
        print_warning "Backend server is already running on port 8080"
        read -p "Stop and restart? [y/N]: " RESTART
        if [[ $RESTART =~ ^[Yy]$ ]]; then
            pkill -f "go run cmd/server/main.go"
            sleep 2
        else
            print_info "Keeping existing server"
            BACKEND_ALREADY_RUNNING=1
        fi
    fi

    # Start backend server
    if [ "${BACKEND_ALREADY_RUNNING}" != "1" ]; then
        print_step "Starting backend server..."
        cd "${PROJECT_DIR}/backend"

        # Create log directory
        mkdir -p "${PROJECT_DIR}/logs"

        nohup go run cmd/server/main.go \
          -addr=:8080 \
          -db="postgres://clipshare:testpass123@localhost:5433/clipshare_test?sslmode=disable" \
          -redis="localhost:6380" \
          -jwt-secret="your-super-secret-jwt-key-change-in-production" \
          > "${PROJECT_DIR}/logs/backend.log" 2>&1 &

        BACKEND_PID=$!
        echo $BACKEND_PID > "${PROJECT_DIR}/backend.pid"

        print_info "Waiting for server to start..."
        sleep 5

        # Test server
        if curl -s http://localhost:8080/healthz | grep -q "ok"; then
            print_success "Backend server is running! (PID: ${BACKEND_PID})"
            print_info "Logs: ${PROJECT_DIR}/logs/backend.log"
        else
            print_error "Backend server failed to start"
            print_info "Check logs: tail -f ${PROJECT_DIR}/logs/backend.log"
            exit 1
        fi
    fi
fi

# Setup macOS App
if [ $SETUP_MACOS -eq 1 ]; then
    if [ "$OS_TYPE" != "macOS" ]; then
        print_warning "Skipping macOS app (not running on macOS)"
    else
        print_header "macOS App Setup"

        # Check Swift
        print_step "Checking for Swift..."
        if command -v swift &> /dev/null; then
            SWIFT_VERSION=$(swift --version | head -n 1)
            print_success "Swift is installed (${SWIFT_VERSION})"
        else
            print_error "Swift is not installed"
            print_info "Install Xcode Command Line Tools: xcode-select --install"
            exit 1
        fi

        # Ask if user wants to build or run
        echo ""
        echo "macOS App Options:"
        echo "  1) Build and run in terminal (debug mode)"
        echo "  2) Build standalone app"
        echo "  3) Skip for now"
        echo ""
        read -p "Enter choice [1-3]: " MACOS_CHOICE

        case $MACOS_CHOICE in
            1)
                print_step "Building and running macOS app..."
                cd "${PROJECT_DIR}/mac-app"
                print_info "App will appear in menubar..."
                print_warning "Press Ctrl+C to stop when done testing"
                swift run
                ;;
            2)
                print_step "Building standalone macOS app..."
                cd "${PROJECT_DIR}/mac-app"
                swift build -c release
                print_success "App built successfully!"
                print_info "Binary location: ${PROJECT_DIR}/mac-app/.build/release/ClipboardMac"
                print_info "Run with: ${PROJECT_DIR}/mac-app/.build/release/ClipboardMac"
                ;;
            *)
                print_info "Skipping macOS app build"
                ;;
        esac
    fi
fi

# Final summary
print_header "Setup Complete! ${ROCKET}"

echo -e "${GREEN}${CHECK} Backend Server Status:${NC}"
if curl -s http://localhost:8080/healthz &> /dev/null; then
    echo -e "   ${GREEN}Running at http://localhost:8080${NC}"
    echo -e "   Test: ${CYAN}curl http://localhost:8080/healthz${NC}"
else
    echo -e "   ${RED}Not running${NC}"
fi

echo ""
echo -e "${GREEN}${CHECK} Database Status:${NC}"
echo -e "   PostgreSQL: localhost:5433"
echo -e "   Redis: localhost:6380"

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}Next Steps:${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ $SETUP_MACOS -eq 1 ] && [ "$OS_TYPE" = "macOS" ]; then
    echo ""
    echo -e "${YELLOW}📱 macOS App:${NC}"
    echo -e "   1. Look for clipboard icon in menubar"
    echo -e "   2. Click → 'Pair Device'"
    echo -e "   3. QR code appears"
fi

echo ""
echo -e "${YELLOW}📱 Android App:${NC}"
echo -e "   1. Open Android Studio"
echo -e "   2. Open: ${PROJECT_DIR}/android-app"
echo -e "   3. Update server URL in PrefsHelper.kt:"
if command -v ifconfig &> /dev/null; then
    LOCAL_IP=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | head -n 1 | awk '{print $2}')
    echo -e "      ${CYAN}return \"ws://${LOCAL_IP}:8080\"${NC}"
else
    echo -e "      ${CYAN}return \"ws://YOUR_IP_ADDRESS:8080\"${NC}"
fi
echo -e "   4. Click Run (green play button)"
echo -e "   5. Scan QR code from macOS app"

echo ""
echo -e "${YELLOW}🧪 Testing:${NC}"
echo -e "   • Copy text on Android → paste on Mac (⌥⌘V)"
echo -e "   • Copy text on Mac → paste on Android"

echo ""
echo -e "${YELLOW}📚 Documentation:${NC}"
echo -e "   • Complete guide: ${CYAN}COMPLETE_SETUP_GUIDE.md${NC}"
echo -e "   • Test results: ${CYAN}TEST_RESULTS.md${NC}"
echo -e "   • Troubleshooting: See COMPLETE_SETUP_GUIDE.md"

echo ""
echo -e "${YELLOW}🛠️  Management:${NC}"
echo -e "   • View logs: ${CYAN}tail -f ${PROJECT_DIR}/logs/backend.log${NC}"
echo -e "   • Stop backend: ${CYAN}pkill -f 'go run cmd/server/main.go'${NC}"
echo -e "   • Stop Docker: ${CYAN}docker-compose -f docker-compose.test.yml down${NC}"
echo -e "   • Restart: ${CYAN}./quick-start.sh${NC}"

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${GREEN}${ROCKET} Happy syncing!${NC}"
echo ""
