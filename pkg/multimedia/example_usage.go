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
	"os"
)

// ExampleUsage demonstrates how to use the multimedia downloader client
func ExampleUsage() error {
	// Initialize the downloader client
	client := NewCacheClient(Config{
		ServiceURL: "http://multimedia-downloader.default.svc.cluster.local",
		Enabled:    true, // Set to false to disable caching
	})

	ctx := context.Background()

	// Fetch an image
	imageURL := "https://example.com/image.jpg"
	body, resp, err := client.FetchMedia(ctx, imageURL)
	if err != nil {
		return fmt.Errorf("failed to fetch media: %w", err)
	}
	defer body.Close()

	// Check cache status
	cacheStatus := GetCacheStatus(resp)
	fmt.Printf("Cache status: %s\n", cacheStatus)
	// Possible values: HIT, MISS, BYPASS, EXPIRED, STALE, UPDATING, REVALIDATED

	// Use the media content
	_, err = io.Copy(os.Stdout, body)
	if err != nil {
		return fmt.Errorf("failed to read media: %w", err)
	}

	return nil
}

// ExampleDirectFetch demonstrates fetching without caching
func ExampleDirectFetch() error {
	// Initialize with caching disabled
	client := NewCacheClient(Config{
		ServiceURL: "http://multimedia-downloader.default.svc.cluster.local",
		Enabled:    false, // Caching disabled
	})

	ctx := context.Background()

	// This will fetch directly from the source
	imageURL := "https://example.com/image.jpg"
	body, _, err := client.FetchMedia(ctx, imageURL)
	if err != nil {
		return fmt.Errorf("failed to fetch media: %w", err)
	}
	defer body.Close()

	// Process the media content
	_, err = io.Copy(os.Stdout, body)
	if err != nil {
		return fmt.Errorf("failed to read media: %w", err)
	}

	return nil
}

// Made with Bob
