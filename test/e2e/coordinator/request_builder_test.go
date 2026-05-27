/*
Copyright 2026 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0
*/

package coordinator

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"time"

	"github.com/onsi/gomega"
)

const (
	// In-cluster URLs for the mock downloaders. The coordinator's
	// replace-media-urls step fetches these during full-pipeline tests.
	downloader1URL = "http://mock-downloader1.default.svc:9000/img.jpg"
	downloader2URL = "http://mock-downloader2.default.svc:9001/img2.jpg"

	// requestTimeout is the per-request HTTP timeout used by httpPostJSON.
	requestTimeout = 60 * time.Second
)

// chatCompletionsTwoImagesBody returns a /v1/chat/completions request body
// with text + two image_url entries pointing at the in-cluster mock
// downloaders. Mirrors the payload shape from curl_two_images.sh.
func chatCompletionsTwoImagesBody() []byte {
	body := map[string]any{
		"model": modelName,
		"messages": []map[string]any{
			{
				"role": "user",
				"content": []map[string]any{
					{"type": "text", "text": "Describe what you see in each image."},
					{"type": "image_url", "image_url": map[string]any{"url": downloader1URL}},
					{"type": "image_url", "image_url": map[string]any{"url": downloader2URL}},
				},
			},
		},
		"max_tokens": 256,
	}
	return mustMarshal(body)
}

// chatCompletionsTextOnlyBody returns a /v1/chat/completions request body
// with a single text message and no media. Exercises the text-only branch
// of the coordinator pipeline (replace-media-urls and encode are no-ops).
func chatCompletionsTextOnlyBody() []byte {
	body := map[string]any{
		"model": modelName,
		"messages": []map[string]any{
			{"role": "user", "content": "Describe San Francisco in one sentence."},
		},
		"max_tokens": 64,
	}
	return mustMarshal(body)
}

func mustMarshal(v any) []byte {
	b, err := json.Marshal(v)
	gomega.Expect(err).NotTo(gomega.HaveOccurred(), "json.Marshal failed")
	return b
}

// httpPostJSON posts the JSON body to url and returns the raw response
// body and HTTP status code. Fails-fast on transport errors via gomega.
func httpPostJSON(url string, body []byte, timeout time.Duration) ([]byte, int) {
	client := &http.Client{Timeout: timeout}
	resp, err := client.Post(url, "application/json", bytes.NewReader(body))
	gomega.Expect(err).NotTo(gomega.HaveOccurred(), "POST %s failed", url)
	defer resp.Body.Close()
	out, err := io.ReadAll(resp.Body)
	gomega.Expect(err).NotTo(gomega.HaveOccurred(), "reading response body")
	return out, resp.StatusCode
}
