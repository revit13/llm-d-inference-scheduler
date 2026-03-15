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
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// CacheClient provides methods to interact with the multimedia cache service
type CacheClient struct {
	baseURL    string
	httpClient *http.Client
	enabled    bool
}

// Config holds configuration for the cache client
type Config struct {
	// ServiceURL is the URL of the multimedia cache service
	// Example: "http://multimedia-cache.default.svc.cluster.local"
	ServiceURL string

	// Enabled controls whether caching is active
	Enabled bool

	// Timeout for HTTP requests
	Timeout time.Duration
}

// NewCacheClient creates a new multimedia cache client
func NewCacheClient(config Config) *CacheClient {
	if config.Timeout == 0 {
		config.Timeout = 30 * time.Second
	}

	return &CacheClient{
		baseURL: config.ServiceURL,
		enabled: config.Enabled,
		httpClient: &http.Client{
			Timeout: config.Timeout,
		},
	}
}

// FetchMedia retrieves media from the cache or downloads it if not cached
// Returns the response body reader and any error encountered
func (c *CacheClient) FetchMedia(ctx context.Context, mediaURL string) (io.ReadCloser, *http.Response, error) {
	if !c.enabled {
		// If caching is disabled, fetch directly
		return c.fetchDirect(ctx, mediaURL)
	}

	// Construct cache service URL
	cacheURL := fmt.Sprintf("%s/fetch?url=%s", c.baseURL, url.QueryEscape(mediaURL))

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, cacheURL, nil)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create request: %w", err)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to fetch from cache: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, nil, fmt.Errorf("cache returned status %d", resp.StatusCode)
	}

	return resp.Body, resp, nil
}

// fetchDirect downloads media directly without caching
func (c *CacheClient) fetchDirect(ctx context.Context, mediaURL string) (io.ReadCloser, *http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, mediaURL, nil)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create direct request: %w", err)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to fetch directly: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, nil, fmt.Errorf("direct fetch returned status %d", resp.StatusCode)
	}

	return resp.Body, resp, nil
}

// GetCacheStatus returns the cache status from response headers
// Possible values: HIT, MISS, BYPASS, EXPIRED, STALE, UPDATING, REVALIDATED
func GetCacheStatus(resp *http.Response) string {
	return resp.Header.Get("X-Cache-Status")
}

// IsEnabled returns whether caching is enabled
func (c *CacheClient) IsEnabled() bool {
	return c.enabled
}

// Made with Bob
