#!/bin/bash

#############################################################################
# Zero-Downtime Blue-Green Deployment Script
# 
# This script implements a production-grade blue-green deployment strategy
# that ensures zero downtime during application updates.
#
# Usage: ./deploy.sh
#############################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
HEALTH_CHECK_ENDPOINT="/health"
HEALTH_CHECK_RETRIES=10
HEALTH_CHECK_INTERVAL=3
NGINX_CONTAINER="taskmanager-nginx"
NGINX_CONFIG_PATH="./nginx/conf.d/default.conf"

#############################################################################
# Helper Functions
#############################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

#############################################################################
# Determine Current Active Environment
#############################################################################

get_active_environment() {
    if grep -q "server app-blue:3000" "$NGINX_CONFIG_PATH"; then
        echo "blue"
    elif grep -q "server app-green:3000" "$NGINX_CONFIG_PATH"; then
        echo "green"
    else
        log_error "Cannot determine active environment from Nginx config"
        exit 1
    fi
}

#############################################################################
# Health Check Function
#############################################################################

check_health() {
    local container=$1
    local port=$2
    local retries=$HEALTH_CHECK_RETRIES
    
    log_info "Checking health of $container (port $port)..."
    
    for i in $(seq 1 $retries); do
        log_info "Health check attempt $i/$retries..."
        
        # Use curl to check health endpoint
        if docker exec $container node -e "
            const http = require('http');
            const options = {
                hostname: 'localhost',
                port: 3000,
                path: '/health',
                method: 'GET',
                timeout: 5000
            };
            const req = http.request(options, (res) => {
                let data = '';
                res.on('data', (chunk) => { data += chunk; });
                res.on('end', () => {
                    if (res.statusCode === 200) {
                        console.log('HEALTHY');
                        process.exit(0);
                    } else {
                        console.log('UNHEALTHY');
                        process.exit(1);
                    }
                });
            });
            req.on('error', () => {
                console.log('ERROR');
                process.exit(1);
            });
            req.on('timeout', () => {
                req.destroy();
                console.log('TIMEOUT');
                process.exit(1);
            });
            req.end();
        " 2>/dev/null | grep -q "HEALTHY"; then
            log_success "$container is healthy!"
            return 0
        fi
        
        if [ $i -lt $retries ]; then
            log_warning "Health check failed. Waiting ${HEALTH_CHECK_INTERVAL}s before retry..."
            sleep $HEALTH_CHECK_INTERVAL
        fi
    done
    
    log_error "$container health check failed after $retries attempts"
    return 1
}

#############################################################################
# Nginx Configuration Update
#############################################################################

update_nginx_config() {
    local new_environment=$1
    
    log_info "Updating Nginx configuration to point to $new_environment environment..."
    
    # Create backup of current config
    cp "$NGINX_CONFIG_PATH" "${NGINX_CONFIG_PATH}.backup"
    
    # Update upstream configuration
    if [ "$new_environment" = "blue" ]; then
        sed -i 's/server app-green:3000/server app-blue:3000/' "$NGINX_CONFIG_PATH"
    else
        sed -i 's/server app-blue:3000/server app-green:3000/' "$NGINX_CONFIG_PATH"
    fi
    
    log_success "Nginx configuration updated"
}

reload_nginx() {
    log_info "Reloading Nginx configuration..."
    
    # Test configuration first
    if docker exec $NGINX_CONTAINER nginx -t 2>&1 | grep -q "successful"; then
        # Reload Nginx (graceful reload, no downtime)
        docker exec $NGINX_CONTAINER nginx -s reload
        log_success "Nginx reloaded successfully"
        return 0
    else
        log_error "Nginx configuration test failed"
        # Restore backup
        mv "${NGINX_CONFIG_PATH}.backup" "$NGINX_CONFIG_PATH"
        return 1
    fi
}

#############################################################################
# Main Deployment Logic
#############################################################################

main() {
    echo ""
    log_info "========================================="
    log_info "  Zero-Downtime Deployment Starting"
    log_info "========================================="
    echo ""
    
    # Step 1: Determine current active environment
    CURRENT_ENV=$(get_active_environment)
    log_info "Current active environment: $CURRENT_ENV"
    
    # Step 2: Determine target environment
    if [ "$CURRENT_ENV" = "blue" ]; then
        TARGET_ENV="green"
        TARGET_CONTAINER="taskmanager-green"
        TARGET_PORT="3002"
        OLD_CONTAINER="taskmanager-blue"
    else
        TARGET_ENV="blue"
        TARGET_CONTAINER="taskmanager-blue"
        TARGET_PORT="3001"
        OLD_CONTAINER="taskmanager-green"
    fi
    
    log_info "Target environment: $TARGET_ENV"
    echo ""
    
    # Step 3: Build new Docker image
    log_info "Building Docker image..."
    docker-compose build
    log_success "Docker image built successfully"
    echo ""
    
    # Step 4: Start target environment
    log_info "Starting $TARGET_ENV environment..."
    
    if [ "$TARGET_ENV" = "green" ]; then
        docker-compose --profile green up -d app-green
    else
        docker-compose up -d app-blue
    fi
    
    log_success "$TARGET_ENV environment started"
    echo ""
    
    # Step 5: Wait for container to be running
    log_info "Waiting for container to be ready..."
    sleep 5
    
    # Step 6: Health check on new environment
    if ! check_health "$TARGET_CONTAINER" "$TARGET_PORT"; then
        log_error "Health check failed on $TARGET_ENV environment"
        log_error "Rolling back - stopping $TARGET_ENV environment"
        docker-compose stop $TARGET_CONTAINER
        exit 1
    fi
    echo ""
    
    # Step 7: Update Nginx configuration
    update_nginx_config "$TARGET_ENV"
    echo ""
    
    # Step 8: Reload Nginx (Zero-Downtime Switch)
    if ! reload_nginx; then
        log_error "Nginx reload failed"
        log_error "Rolling back configuration..."
        mv "${NGINX_CONFIG_PATH}.backup" "$NGINX_CONFIG_PATH"
        exit 1
    fi
    
    # Remove backup after successful reload
    rm -f "${NGINX_CONFIG_PATH}.backup"
    echo ""
    
    # Step 9: Verify the switch
    log_info "Verifying traffic is routed to $TARGET_ENV..."
    sleep 2
    
    if curl -s http://localhost/health | grep -q "\"version\":\"$TARGET_ENV\""; then
        log_success "Traffic successfully switched to $TARGET_ENV environment!"
    else
        log_warning "Could not verify environment switch, but Nginx reload was successful"
    fi
    echo ""
    
    # Step 10: Keep old environment running for rollback capability
    log_info "Keeping $CURRENT_ENV environment running for potential rollback"
    log_info "To stop the old environment, run: docker-compose stop $OLD_CONTAINER"
    echo ""
    
    # Deployment complete
    log_success "========================================="
    log_success "  Deployment Completed Successfully!"
    log_success "========================================="
    echo ""
    log_info "Active Environment: $TARGET_ENV"
    log_info "Standby Environment: $CURRENT_ENV (running for rollback)"
    log_info "Application URL: http://localhost"
    log_info "Health Check: http://localhost/health"
    echo ""
    log_info "To rollback, run: ./deploy.sh (will switch back automatically)"
    echo ""
}

# Run main function
main
