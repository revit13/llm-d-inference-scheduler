package prefixhashtable

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestPrefixHashTable_AddAndMatch(t *testing.T) {
	table := NewPrefixHashTable(nil)

	prompt := []string{"The", "capital", "of", "France", "is"}
	token := []uint32{uint32(15496)}

	hashes := table.GetPrefixHashes(prompt)
	t.Log("hases:", hashes[len(hashes)-1])
	table.AddTokenPrefix(hashes[0], token)
	table.AddTokenPrefix(hashes[1], token)

	result := table.getPrefixBlocks(hashes)

	assert.NotEmpty(t, result)
	assert.Equal(t, result[hashes[len(hashes)-1]].Tokens[0], token[0])
}

func TestPrefixHashTable_LRUEviction(t *testing.T) {
	// Use a small cache to force eviction
	DefaultMaxBlockNumber = 2
	table := NewPrefixHashTable(nil)

	token := []uint32{uint32(15496)}
	prompts := [][]string{
		{"a", "b"}, // will be evicted
		{"c", "d"},
		{"e", "f"},
	}

	for i := range prompts {
		hashes := table.GetPrefixHashes(prompts[i])
		table.AddTokenPrefix(hashes[len(hashes)-1], token)
	}

	// First prompt should be evicted
	hashesPrompt0 := table.GetPrefixHashes(prompts[0])
	result := table.getPrefixBlocks(hashesPrompt0)
	assert.Empty(t, result, "First prompt should be evicted")

	// Last prompt should still be in cache
	hashesPrompt2 := table.GetPrefixHashes(prompts[2])
	result2 := table.getPrefixBlocks(hashesPrompt2)
	assert.Equal(t, result2[hashesPrompt2[0]].Tokens[0], token[0])
}
