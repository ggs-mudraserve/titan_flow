#!/bin/bash
# TitanFlow Production Deployment Script
# Usage: ./deploy.sh [build|deploy|restart|status|logs]

set -e

APP_NAME="titan_flow"
APP_DIR="/root/titan_flow"
RELEASE_DIR="$APP_DIR/_build/prod/rel/$APP_NAME"
SERVICE_NAME="titan_flow"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

build() {
    log_info "Building production release..."
    cd $APP_DIR
    
    # Load environment
    if [ -f ".env.production" ]; then
        export $(cat .env.production | grep -v '^#' | xargs)
    fi
    
    # Clean previous build
    log_info "Cleaning previous build..."
    rm -rf _build/prod
    
    # Get dependencies
    log_info "Getting dependencies..."
    MIX_ENV=prod mix deps.get --only prod
    
    # Compile assets
    log_info "Compiling assets..."
    MIX_ENV=prod mix assets.deploy
    
    # Compile application
    log_info "Compiling application..."
    MIX_ENV=prod mix compile
    
    # Build release
    log_info "Building release..."
    MIX_ENV=prod mix release --overwrite
    
    log_info "Build complete! Release at: $RELEASE_DIR"
}

deploy() {
    log_info "Deploying TitanFlow..."
    
    # Run migrations
    log_info "Running migrations..."
    cd $APP_DIR
    if [ -f ".env.production" ]; then
        export $(cat .env.production | grep -v '^#' | xargs)
    fi
    MIX_ENV=prod mix ecto.migrate
    
    # Restart service
    log_info "Restarting service..."
    sudo systemctl restart $SERVICE_NAME
    
    sleep 5
    
    # Check status
    if systemctl is-active --quiet $SERVICE_NAME; then
        log_info "Deployment successful! Service is running."
    else
        log_error "Service failed to start. Check logs with: journalctl -u $SERVICE_NAME -f"
        exit 1
    fi
}

restart() {
    log_info "Restarting TitanFlow service..."
    sudo systemctl restart $SERVICE_NAME
    sleep 3
    status
}

status() {
    echo ""
    log_info "Service Status:"
    sudo systemctl status $SERVICE_NAME --no-pager -l
    echo ""
    log_info "Quick Health Check:"
    curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://localhost:4000/ || echo "Service not responding"
}

logs() {
    log_info "Showing live logs (Ctrl+C to exit)..."
    sudo journalctl -u $SERVICE_NAME -f
}

install_service() {
    log_info "Installing systemd service..."
    
    # Copy service file
    sudo cp $APP_DIR/deploy/titan_flow.service /etc/systemd/system/
    
    # Reload systemd
    sudo systemctl daemon-reload
    
    # Enable service
    sudo systemctl enable $SERVICE_NAME
    
    log_info "Service installed and enabled."
}

case "$1" in
    build)
        build
        ;;
    deploy)
        deploy
        ;;
    restart)
        restart
        ;;
    status)
        status
        ;;
    logs)
        logs
        ;;
    install)
        install_service
        ;;
    full)
        build
        deploy
        ;;
    *)
        echo "Usage: $0 {build|deploy|restart|status|logs|install|full}"
        echo ""
        echo "Commands:"
        echo "  build   - Build production release"
        echo "  deploy  - Run migrations and restart service"
        echo "  restart - Restart the service"
        echo "  status  - Show service status"
        echo "  logs    - Show live logs"
        echo "  install - Install systemd service"
        echo "  full    - Build and deploy"
        exit 1
        ;;
esac
