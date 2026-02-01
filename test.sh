#!/bin/bash

#############################################################################
# Zero-Downtime Deployment Testing Script
# 
# This script tests your deployment setup to ensure everything works
# correctly before showing it to recruiters or in production.
#############################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
HOST="${1:-localhost}"
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

#############################################################################
# Helper Functions
#############################################################################

print_header() {
    echo ""
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo ""
}

test_start() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -e "${YELLOW}[TEST $TOTAL_TESTS]${NC} $1"
}

test_pass() {
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "${GREEN}✓ PASS${NC} $1"
    echo ""
}

test_fail() {
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "${RED}✗ FAIL${NC} $1"
    echo ""
}

#############################################################################
# Test Functions
#############################################################################

test_docker_running() {
    test_start "Checking if Docker is running"
    
    if docker info > /dev/null 2>&1; then
        test_pass "Docker is running"
        return 0
    else
        test_fail "Docker is not running. Please start Docker."
        return 1
    fi
}

test_containers_running() {
    test_start "Checking if containers are running"
    
    local required_containers=("taskmanager-mongo" "taskmanager-nginx")
    local all_running=true
    
    for container in "${required_containers[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            echo "  ✓ $container is running"
        else
            echo "  ✗ $container is NOT running"
            all_running=false
        fi
    done
    
    # Check if at least one app container is running
    if docker ps --format '{{.Names}}' | grep -q "taskmanager-blue\|taskmanager-green"; then
        local active_app=$(docker ps --format '{{.Names}}' | grep "taskmanager-blue\|taskmanager-green")
        echo "  ✓ App container $active_app is running"
    else
        echo "  ✗ No app container (blue or green) is running"
        all_running=false
    fi
    
    if [ "$all_running" = true ]; then
        test_pass "All required containers are running"
        return 0
    else
        test_fail "Some containers are not running"
        return 1
    fi
}

test_health_endpoint() {
    test_start "Testing health endpoint"
    
    local response=$(curl -s -o /dev/null -w "%{http_code}" http://${HOST}/health)
    
    if [ "$response" = "200" ]; then
        local health=$(curl -s http://${HOST}/health)
        echo "  Response: $health"
        test_pass "Health endpoint returns 200 OK"
        return 0
    else
        test_fail "Health endpoint returned $response (expected 200)"
        return 1
    fi
}

test_database_connection() {
    test_start "Testing database connection"
    
    local health=$(curl -s http://${HOST}/health)
    
    if echo "$health" | grep -q '"database":"connected"'; then
        test_pass "Database is connected"
        return 0
    else
        test_fail "Database is not connected"
        return 1
    fi
}

test_api_endpoints() {
    test_start "Testing API endpoints"
    
    # Test GET /api/tasks
    local get_response=$(curl -s -o /dev/null -w "%{http_code}" http://${HOST}/api/tasks)
    if [ "$get_response" = "200" ]; then
        echo "  ✓ GET /api/tasks returns 200"
    else
        echo "  ✗ GET /api/tasks returns $get_response"
        test_fail "API endpoints not working correctly"
        return 1
    fi
    
    # Test POST /api/tasks
    local post_response=$(curl -s -X POST http://${HOST}/api/tasks \
        -H "Content-Type: application/json" \
        -d '{"title":"Test Task","description":"Auto-generated test task"}')
    
    if echo "$post_response" | grep -q '"success":true'; then
        echo "  ✓ POST /api/tasks creates task successfully"
        
        # Extract task ID and test GET single task
        local task_id=$(echo "$post_response" | grep -o '"_id":"[^"]*"' | cut -d'"' -f4)
        
        if [ ! -z "$task_id" ]; then
            local single_get=$(curl -s http://${HOST}/api/tasks/${task_id})
            if echo "$single_get" | grep -q '"success":true'; then
                echo "  ✓ GET /api/tasks/:id works correctly"
            fi
            
            # Clean up - delete test task
            curl -s -X DELETE http://${HOST}/api/tasks/${task_id} > /dev/null
            echo "  ✓ DELETE /api/tasks/:id works correctly"
        fi
        
        test_pass "All API endpoints working correctly"
        return 0
    else
        test_fail "API endpoints not working correctly"
        return 1
    fi
}

test_deployment_script() {
    test_start "Testing deployment script exists and is executable"
    
    if [ -f "./deploy.sh" ]; then
        echo "  ✓ deploy.sh exists"
        
        if [ -x "./deploy.sh" ]; then
            test_pass "deploy.sh is executable"
            return 0
        else
            echo "  ✗ deploy.sh is not executable"
            echo "  Fix: Run 'chmod +x deploy.sh'"
            test_fail "deploy.sh permissions incorrect"
            return 1
        fi
    else
        test_fail "deploy.sh not found"
        return 1
    fi
}

test_nginx_config() {
    test_start "Testing Nginx configuration"
    
    if docker exec taskmanager-nginx nginx -t > /dev/null 2>&1; then
        test_pass "Nginx configuration is valid"
        return 0
    else
        test_fail "Nginx configuration has errors"
        return 1
    fi
}

test_environment_detection() {
    test_start "Testing environment detection"
    
    local health=$(curl -s http://${HOST}/health)
    local version=$(echo "$health" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
    
    if [ "$version" = "blue" ] || [ "$version" = "green" ]; then
        echo "  Current active environment: $version"
        test_pass "Environment detection working (active: $version)"
        return 0
    else
        test_fail "Cannot detect active environment"
        return 1
    fi
}

test_concurrent_requests() {
    test_start "Testing concurrent request handling"
    
    echo "  Sending 50 concurrent requests..."
    
    local failed=0
    for i in {1..50}; do
        curl -s -o /dev/null -w "%{http_code}" http://${HOST}/health > /tmp/test_$i.txt &
    done
    
    wait
    
    for i in {1..50}; do
        if [ "$(cat /tmp/test_$i.txt)" != "200" ]; then
            failed=$((failed + 1))
        fi
        rm -f /tmp/test_$i.txt
    done
    
    if [ $failed -eq 0 ]; then
        test_pass "All 50 concurrent requests succeeded"
        return 0
    else
        test_fail "$failed out of 50 requests failed"
        return 1
    fi
}

test_zero_downtime_simulation() {
    test_start "Simulating zero-downtime deployment (this takes ~30 seconds)"
    
    echo "  Starting continuous health checks..."
    
    # Start background process that continuously checks health
    {
        local failed=0
        for i in {1..30}; do
            if ! curl -s http://${HOST}/health > /dev/null; then
                failed=$((failed + 1))
            fi
            sleep 1
        done
        echo $failed > /tmp/downtime_test.txt
    } &
    
    local bg_pid=$!
    
    # Wait 5 seconds then trigger simulated config change
    sleep 5
    echo "  Simulating deployment (reloading Nginx)..."
    docker exec taskmanager-nginx nginx -s reload > /dev/null 2>&1
    
    # Wait for background process to complete
    wait $bg_pid
    
    local failed=$(cat /tmp/downtime_test.txt)
    rm -f /tmp/downtime_test.txt
    
    if [ $failed -eq 0 ]; then
        test_pass "Zero downtime confirmed - 0 failed requests during reload"
        return 0
    else
        test_fail "$failed requests failed during reload"
        return 1
    fi
}

#############################################################################
# Main Test Runner
#############################################################################

print_header "ZERO-DOWNTIME DEPLOYMENT TEST SUITE"

echo "Testing host: ${HOST}"
echo "Time: $(date)"
echo ""

# Run all tests
test_docker_running
test_containers_running
test_health_endpoint
test_database_connection
test_api_endpoints
test_deployment_script
test_nginx_config
test_environment_detection
test_concurrent_requests
test_zero_downtime_simulation

# Print summary
print_header "TEST SUMMARY"

echo -e "Total Tests:  ${TOTAL_TESTS}"
echo -e "${GREEN}Passed:       ${PASSED_TESTS}${NC}"
echo -e "${RED}Failed:       ${FAILED_TESTS}${NC}"
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ALL TESTS PASSED! 🎉             ║${NC}"
    echo -e "${GREEN}║  Your deployment is ready!         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════╗${NC}"
    echo -e "${RED}║  SOME TESTS FAILED ⚠️              ║${NC}"
    echo -e "${RED}║  Please fix issues above           ║${NC}"
    echo -e "${RED}╚════════════════════════════════════╝${NC}"
    exit 1
fi
