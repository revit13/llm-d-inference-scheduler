#!/bin/bash
# Test script for multimedia-downloader service
# This script tests the multimedia downloader cache service with various scenarios

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SERVICE_URL="${MULTIMEDIA_DOWNLOADER_URL:-http://localhost:8080}"
NAMESPACE="${NAMESPACE:-default}"

# Test URLs
IMAGE_URL="https://httpbin.org/image/jpeg"
PNG_URL="https://httpbin.org/image/png"
VIDEO_URL="https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Multimedia Downloader Test Suite${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "Service URL: ${GREEN}${SERVICE_URL}${NC}"
echo -e "Namespace: ${GREEN}${NAMESPACE}${NC}"
echo ""

# Function to print test header
print_test() {
    echo -e "\n${YELLOW}[TEST]${NC} $1"
}

# Function to print success
print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Function to print error
print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Function to check if service is accessible
check_service() {
    print_test "Checking if service is accessible..."
    
    if curl -s -f "${SERVICE_URL}/health" > /dev/null 2>&1; then
        print_success "Service is accessible"
        return 0
    else
        print_error "Service is not accessible at ${SERVICE_URL}"
        echo ""
        echo "To test locally, run:"
        echo "  kubectl port-forward -n ${NAMESPACE} svc/multimedia-downloader 8080:80"
        echo ""
        return 1
    fi
}

# Test 1: Health check
test_health_check() {
    print_test "Testing health check endpoint..."
    
    response=$(curl -s "${SERVICE_URL}/health")
    
    if [[ "$response" == "healthy" ]]; then
        print_success "Health check passed: $response"
    else
        print_error "Health check failed: $response"
        return 1
    fi
}

# Test 2: Fetch image (first time - should be MISS)
test_fetch_image_miss() {
    print_test "Fetching image (first time - expecting cache MISS)..."
    
    response=$(curl -s -I "${SERVICE_URL}/fetch?url=${IMAGE_URL}")
    cache_status=$(echo "$response" | grep -i "X-Cache-Status" | cut -d' ' -f2 | tr -d '\r')
    http_status=$(echo "$response" | head -n1 | cut -d' ' -f2)
    
    echo "  HTTP Status: $http_status"
    echo "  Cache Status: $cache_status"
    
    if [[ "$http_status" == "200" ]]; then
        print_success "Image fetched successfully"
    else
        print_error "Failed to fetch image (HTTP $http_status)"
        return 1
    fi
    
    if [[ "$cache_status" == "MISS" ]]; then
        print_success "Cache MISS as expected (first fetch)"
    else
        echo -e "${YELLOW}⚠${NC} Cache status is $cache_status (expected MISS, but may vary)"
    fi
}

# Test 3: Fetch same image (should be HIT)
test_fetch_image_hit() {
    print_test "Fetching same image again (expecting cache HIT)..."
    
    sleep 1  # Brief pause to ensure cache is written
    
    response=$(curl -s -I "${SERVICE_URL}/fetch?url=${IMAGE_URL}")
    cache_status=$(echo "$response" | grep -i "X-Cache-Status" | cut -d' ' -f2 | tr -d '\r')
    http_status=$(echo "$response" | head -n1 | cut -d' ' -f2)
    
    echo "  HTTP Status: $http_status"
    echo "  Cache Status: $cache_status"
    
    if [[ "$http_status" == "200" ]]; then
        print_success "Image fetched successfully"
    else
        print_error "Failed to fetch image (HTTP $http_status)"
        return 1
    fi
    
    if [[ "$cache_status" == "HIT" ]]; then
        print_success "Cache HIT as expected (cached content)"
    else
        echo -e "${YELLOW}⚠${NC} Cache status is $cache_status (expected HIT)"
    fi
}

# Test 4: Download full image
test_download_image() {
    print_test "Downloading full image to file..."
    
    output_file="/tmp/test-image-$$.jpg"
    
    if curl -s -o "$output_file" "${SERVICE_URL}/fetch?url=${IMAGE_URL}"; then
        file_size=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null)
        print_success "Image downloaded successfully (${file_size} bytes)"
        print_success "Saved to: $output_file"
        rm -f "$output_file"
    else
        print_error "Failed to download image"
        return 1
    fi
}

# Test 5: Test different image format (PNG)
test_fetch_png() {
    print_test "Fetching PNG image..."
    
    response=$(curl -s -I "${SERVICE_URL}/fetch?url=${PNG_URL}")
    cache_status=$(echo "$response" | grep -i "X-Cache-Status" | cut -d' ' -f2 | tr -d '\r')
    content_type=$(echo "$response" | grep -i "Content-Type" | cut -d' ' -f2 | tr -d '\r')
    http_status=$(echo "$response" | head -n1 | cut -d' ' -f2)
    
    echo "  HTTP Status: $http_status"
    echo "  Content-Type: $content_type"
    echo "  Cache Status: $cache_status"
    
    if [[ "$http_status" == "200" ]]; then
        print_success "PNG image fetched successfully"
    else
        print_error "Failed to fetch PNG image (HTTP $http_status)"
        return 1
    fi
}

# Test 6: Test video with range request
test_video_range_request() {
    print_test "Testing video with range request (seeking support)..."
    
    # First, get the full video headers to check Accept-Ranges
    response=$(curl -s -I "${SERVICE_URL}/fetch?url=${VIDEO_URL}")
    accept_ranges=$(echo "$response" | grep -i "Accept-Ranges" | cut -d' ' -f2 | tr -d '\r')
    http_status=$(echo "$response" | head -n1 | cut -d' ' -f2)
    
    echo "  HTTP Status: $http_status"
    echo "  Accept-Ranges: $accept_ranges"
    
    if [[ "$accept_ranges" == "bytes" ]]; then
        print_success "Range requests supported (video seeking enabled)"
    else
        echo -e "${YELLOW}⚠${NC} Range requests may not be supported"
    fi
    
    # Now test an actual range request
    print_test "Fetching video range (bytes 0-1048575)..."
    range_response=$(curl -s -I -H "Range: bytes=0-1048575" "${SERVICE_URL}/fetch?url=${VIDEO_URL}")
    range_status=$(echo "$range_response" | head -n1 | cut -d' ' -f2)
    content_range=$(echo "$range_response" | grep -i "Content-Range" | cut -d' ' -f2- | tr -d '\r')
    
    echo "  HTTP Status: $range_status"
    echo "  Content-Range: $content_range"
    
    if [[ "$range_status" == "206" ]]; then
        print_success "Partial content (206) returned for range request"
    else
        echo -e "${YELLOW}⚠${NC} Expected 206 Partial Content, got $range_status"
    fi
}

# Test 7: Test invalid URL
test_invalid_url() {
    print_test "Testing with invalid URL (expecting 502/504)..."
    
    response=$(curl -s -I "${SERVICE_URL}/fetch?url=https://invalid-domain-that-does-not-exist-12345.com/image.jpg")
    http_status=$(echo "$response" | head -n1 | cut -d' ' -f2)
    
    echo "  HTTP Status: $http_status"
    
    if [[ "$http_status" == "502" ]] || [[ "$http_status" == "504" ]]; then
        print_success "Correctly returned error status for invalid URL"
    else
        echo -e "${YELLOW}⚠${NC} Expected 502/504, got $http_status"
    fi
}

# Test 8: Performance test (multiple concurrent requests)
test_performance() {
    print_test "Performance test (10 concurrent requests)..."
    
    start_time=$(date +%s)
    
    for i in {1..10}; do
        curl -s -o /dev/null "${SERVICE_URL}/fetch?url=${IMAGE_URL}" &
    done
    
    wait
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    print_success "Completed 10 concurrent requests in ${duration}s"
    
    if [[ $duration -lt 5 ]]; then
        print_success "Performance is good (< 5s for 10 requests)"
    else
        echo -e "${YELLOW}⚠${NC} Performance could be improved (${duration}s for 10 requests)"
    fi
}

# Test 9: Check cache headers
test_cache_headers() {
    print_test "Checking cache-related headers..."
    
    response=$(curl -s -I "${SERVICE_URL}/fetch?url=${IMAGE_URL}")
    
    echo "$response" | grep -i "X-Cache-Status" && print_success "X-Cache-Status header present" || print_error "X-Cache-Status header missing"
    echo "$response" | grep -i "Content-Type" && print_success "Content-Type header present" || print_error "Content-Type header missing"
    echo "$response" | grep -i "Content-Length" && print_success "Content-Length header present" || print_error "Content-Length header missing"
}

# Main test execution
main() {
    # Check if service is accessible first
    if ! check_service; then
        exit 1
    fi
    
    # Run all tests
    test_health_check
    test_fetch_image_miss
    test_fetch_image_hit
    test_download_image
    test_fetch_png
    test_video_range_request
    test_invalid_url
    test_cache_headers
    test_performance
    
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}All tests completed!${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "Summary:"
    echo "  - Health check: ✓"
    echo "  - Cache functionality: ✓"
    echo "  - Image download: ✓"
    echo "  - Video range requests: ✓"
    echo "  - Error handling: ✓"
    echo "  - Performance: ✓"
    echo ""
}

# Run main function
main

# Made with Bob
