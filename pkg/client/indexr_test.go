package client_test

import (
	"testing"

	"github.com/neuralmagic/distributed-kv-cache/pkg/client"
	"github.com/stretchr/testify/assert"
)

// TestPrefixUpdateAndMatch verifies that prefix hashes are empty before update
// and return the correct pod after UpdatePodPrefix is called.
func TestPrefixUpdateAndMatch(t *testing.T) {
	indexer := client.NewKVCacheIndexer()
	prompt := []string{"The", "sky", "is"}
	model := indexer.ModelInfo{Name: "llm", Version: "v1"}

	t.Logf("Using strategy: %s", indexer.Scorer.Strategy())

	// Run lookup before update
	pods, err := indexer.ExtractPrefixPods(prompt, model)
	assert.NoError(t, err)
	assert.Empty(t, pods, "Expected no matches before prefix update")

	hashes := indexer.PrefixCache.GetPrefixHashes(prompt)
	for _, h := range hashes {
		indexer.PrefixCache.UpdatePodPrefix(h, "pod-a")
	}

	// Lookup again — should now return pod-a
	updatedPods, err := indexer.ExtractPrefixPods(prompt, model)
	assert.NoError(t, err)
	assert.NotEmpty(t, updatedPods, "Expected pods after prefix update")

	// Ensure pod-a exists in the results
	found := false
	for _, pod := range updatedPods {
		if pod.Name == "pod-a" {
			found = true
			break
		}
	}
	assert.True(t, found, "Expected to find pod-a in updated results")
}
