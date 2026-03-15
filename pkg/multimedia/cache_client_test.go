/*
Copyright 2025 The llm-d Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

	http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package multimedia

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// TestCacheClient_FetchMedia_Disabled tests direct fetch when caching is disabled
func TestCacheClient_FetchMedia_Disabled(t *testing.T) {
	// Create a test server that returns test content
	testContent := "test image content"
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/jpeg")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(testContent))
	}))
	defer ts.Close()

	// Create client with caching disabled
	client := NewCacheClient(Config{
		ServiceURL: "http://cache-service",
		Enabled:    false,
		Timeout:    5 * time.Second,
	})

	// Fetch media
	ctx := context.Background()
	body, resp, err := client.FetchMedia(ctx, ts.URL)
	if err != nil {
		t.Fatalf("FetchMedia failed: %v", err)
	}
	defer body.Close()

	// Verify response
	if resp.StatusCode != http.StatusOK {
		t.Errorf("Expected status 200, got %d", resp.StatusCode)
	}

	// Read content
	content, err := io.ReadAll(body)
	if err != nil {
		t.Fatalf("Failed to read body: %v", err)
	}

	if string(content) != testContent {
		t.Errorf("Expected content %q, got %q", testContent, string(content))
	}
}

// TestCacheClient_FetchMedia_Enabled tests fetch through cache service
func TestCacheClient_FetchMedia_Enabled(t *testing.T) {
	testContent := "cached image content"
	
	// Create a mock cache service
	cacheHits := 0
	cacheServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/fetch" {
			t.Errorf("Expected path /fetch, got %s", r.URL.Path)
		}

		// Check if URL parameter is present
		url := r.URL.Query().Get("url")
		if url == "" {
			t.Error("Expected url parameter")
		}

		// Simulate cache behavior
		cacheHits++
		if cacheHits == 1 {
			w.Header().Set("X-Cache-Status", "MISS")
		} else {
			w.Header().Set("X-Cache-Status", "HIT")
		}

		w.Header().Set("Content-Type", "image/jpeg")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(testContent))
	}))
	defer cacheServer.Close()

	// Create client with caching enabled
	client := NewCacheClient(Config{
		ServiceURL: cacheServer.URL,
		Enabled:    true,
		Timeout:    5 * time.Second,
	})

	// First fetch (should be MISS)
	ctx := context.Background()
	body1, resp1, err := client.FetchMedia(ctx, "https://example.com/image.jpg")
	if err != nil {
		t.Fatalf("First FetchMedia failed: %v", err)
	}
	defer body1.Close()

	cacheStatus1 := GetCacheStatus(resp1)
	if cacheStatus1 != "MISS" {
		t.Errorf("Expected cache status MISS, got %s", cacheStatus1)
	}

	content1, _ := io.ReadAll(body1)
	if string(content1) != testContent {
		t.Errorf("Expected content %q, got %q", testContent, string(content1))
	}

	// Second fetch (should be HIT)
	body2, resp2, err := client.FetchMedia(ctx, "https://example.com/image.jpg")
	if err != nil {
		t.Fatalf("Second FetchMedia failed: %v", err)
	}
	defer body2.Close()

	cacheStatus2 := GetCacheStatus(resp2)
	if cacheStatus2 != "HIT" {
		t.Errorf("Expected cache status HIT, got %s", cacheStatus2)
	}

	content2, _ := io.ReadAll(body2)
	if string(content2) != testContent {
		t.Errorf("Expected content %q, got %q", testContent, string(content2))
	}
}

// TestCacheClient_IsEnabled tests the IsEnabled method
func TestCacheClient_IsEnabled(t *testing.T) {
	tests := []struct {
		name    string
		enabled bool
	}{
		{"Enabled", true},
		{"Disabled", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client := NewCacheClient(Config{
				ServiceURL: "http://cache-service",
				Enabled:    tt.enabled,
			})

			if client.IsEnabled() != tt.enabled {
				t.Errorf("Expected IsEnabled() = %v, got %v", tt.enabled, client.IsEnabled())
			}
		})
	}
}

// TestGetCacheStatus tests the GetCacheStatus helper function
func TestGetCacheStatus(t *testing.T) {
	tests := []struct {
		name           string
		headerValue    string
		expectedStatus string
	}{
		{"HIT", "HIT", "HIT"},
		{"MISS", "MISS", "MISS"},
		{"EXPIRED", "EXPIRED", "EXPIRED"},
		{"Empty", "", ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resp := &http.Response{
				Header: http.Header{},
			}
			if tt.headerValue != "" {
				resp.Header.Set("X-Cache-Status", tt.headerValue)
			}

			status := GetCacheStatus(resp)
			if status != tt.expectedStatus {
				t.Errorf("Expected status %q, got %q", tt.expectedStatus, status)
			}
		})
	}
}

// TestCacheClient_FetchMedia_Error tests error handling
func TestCacheClient_FetchMedia_Error(t *testing.T) {
	// Create client pointing to non-existent service
	client := NewCacheClient(Config{
		ServiceURL: "http://localhost:99999",
		Enabled:    true,
		Timeout:    1 * time.Second,
	})

	ctx := context.Background()
	_, _, err := client.FetchMedia(ctx, "https://example.com/image.jpg")
	if err == nil {
		t.Error("Expected error for non-existent service, got nil")
	}
}

// Made with Bob