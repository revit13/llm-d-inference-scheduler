/*
Copyright 2026 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0
*/

package coordinator

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
)

var _ = ginkgo.Describe("e-p-d-pools env", func() {
	ginkgo.It("AllPoolsWired: encode, prefill, decode InferencePools exist", func() {
		expectAllPoolsExist(testConfig)
	})

	ginkgo.It("TwoImages_ChatCompletions_OpenAI: full pipeline returns chat.completion", func() {
		body := chatCompletionsTwoImagesBody()
		raw, status := httpPostJSON(coordinatorBaseURL+"/v1/chat/completions", body, requestTimeout)
		expectChatCompletion(raw, status)
	})

	ginkgo.It("TextOnly_ChatCompletions: text-only pipeline returns chat.completion", func() {
		body := chatCompletionsTextOnlyBody()
		raw, status := httpPostJSON(coordinatorBaseURL+"/v1/chat/completions", body, requestTimeout)
		expectChatCompletion(raw, status)
	})
})

// chatCompletionResponse captures the subset of the OpenAI chat-completion
// schema the tests assert against. Fields the simulator fills with canned
// values (id, choices[].message.content) need only be non-empty; we assert
// shape, not content correctness.
type chatCompletionResponse struct {
	ID      string `json:"id"`
	Object  string `json:"object"`
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
	Usage map[string]any `json:"usage"`
}

// expectChatCompletion asserts the request returned 200 with a body that
// parses as an OpenAI chat.completion and that the EPP did not leak its
// internal `tokens` field back to the client.
func expectChatCompletion(raw []byte, status int) {
	gomega.Expect(status).To(gomega.Equal(http.StatusOK), "non-200 from coordinator: %s", string(raw))

	var parsed chatCompletionResponse
	gomega.Expect(json.Unmarshal(raw, &parsed)).To(gomega.Succeed(), "response is not valid JSON: %s", string(raw))
	gomega.Expect(parsed.ID).NotTo(gomega.BeEmpty(), "missing id field")
	gomega.Expect(parsed.Object).To(gomega.Equal("chat.completion"))
	gomega.Expect(parsed.Choices).NotTo(gomega.BeEmpty(), "missing choices")
	gomega.Expect(parsed.Choices[0].Message.Content).NotTo(gomega.BeEmpty(), "empty message content")
	gomega.Expect(parsed.Usage).NotTo(gomega.BeNil(), "missing usage block")

	// EPP strips its internal tokens object before forwarding. A regression
	// would re-leak it; check by substring rather than parsing because the
	// shape is internal and may evolve.
	gomega.Expect(strings.Contains(string(raw), `"tokens":{`)).
		To(gomega.BeFalse(), "internal tokens field leaked to client: %s", string(raw))
}
