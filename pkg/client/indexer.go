package client

/*

import (
	"context"
	"errors"
	"fmt"
	"github.com/neuralmagic/distributed-kv-cache/pkg/tokenization"
	"strings"

	"github.com/neuralmagic/distributed-kv-cache/pkg/prefixhashtable"
	"github.com/redis/go-redis/v9"
	"github.com/sirupsen/logrus"
)


const (
	// DefaultLMChunkSize defines the default number of tokens per block for LM-style prefix hashing.
	DefaultLMChunkSize = 256
)

// Pod represents a pod with its score used for KV-aware routing decisions.
type Pod struct {
	Name  string
	Score float64
}

// Tokens is a custom type representing a sequence of token IDs.
type Tokens []uint32

// ModelInfo holds model name and version metadata for prefix operations.
type ModelInfo struct {
	Name    string
	Version string
}

// Config configures the KVCacheIndexer with hashing, Redis Remote Addr,
// and token chunking settings.
type Config struct {
	PrefixHashConfig prefixhashtable.Config
	LMChunkSize      int
	RedisAddr        string
}

// KVCacheIndexer manages token-prefix mappings, block scoring, Redis hits, and filtering logic.
type KVCacheIndexer struct {
	logger           *logrus.Entry
	PrefixCache      *prefixhashtable.PrefixHashTable
	lMCacheChunkSize int
	redisClient      *redis.Client
	tokenizer        *tokenization.Tokenizer
}

// ExtractPrefixTokens returns tokens from prefix-matched blocks and indicates whether an index update is needed.
func (k *KVCacheIndexer) ExtractPrefixTokens(prompt []string, modelInfo ModelInfo) (Tokens, bool, error) {
	k.logger.Infof("Looking up prefix for model=%s, prompt len=%d", modelInfo.Name, len(prompt))

	matches, hashes := k.PrefixCache.GetPrefixBlocks(prompt)

	needsUpdate := len(matches) != len(hashes)
	var tokens Tokens

	for _, block := range matches {
		tokens = append(tokens, block.Tokens...)
	}
	k.logger.Infof("Found %d matches vs %d prompt tokens → needsUpdate=%v", len(matches), len(prompt), needsUpdate)

	return tokens, needsUpdate, nil
}

// ExtractPrefixPods looks up prefix matches for a prompt and returns a list of unique pods,
// each with the highest score observed across matched blocks.
// The score is calculated based on the position of the block (later blocks = higher score).
func (k *KVCacheIndexer) ExtractPrefixPods(prompt []string, modelInfo ModelInfo) ([]Pod, error) {
	k.logger.Infof("Looking up prefix for model=%s, prompt len=%d", modelInfo.Name, len(prompt))

	// Get prefix-matched blocks and their hashes
	matches, hashes := k.PrefixCache.GetPrefixBlocks(prompt)

	// Track highest score seen per pod
	podScores := make(map[string]float64)

	for idx, hash := range hashes {
		block := matches[hash]

		// Score is normalized to 0-100 range based on block position
		score := (float64(idx+1) / float64(len(hashes))) * 100

		for _, pod := range block.Pods {
			// If pod is new or this score is higher, update the map
			if existingScore, exists := podScores[pod.Name]; !exists || score > existingScore {
				podScores[pod.Name] = score
			}
		}
	}

	// Convert the score map to a slice of Pod structs
	pods := make([]Pod, 0, len(podScores))
	for name, score := range podScores {
		pods = append(pods, Pod{Name: name, Score: score})
	}

	return pods, nil
}

// TriggerPrefixIndexUpdate asynchronously tokenizes and stores the last prefix hash of each prompt block.
func (k *KVCacheIndexer) TriggerPrefixIndexUpdate(prompt []string, modelInfo ModelInfo) error {
	chunkPrompts := k.PrefixCache.ChunkPrompt(prompt)
	for i := 1; i <= len(chunkPrompts); i++ {
		// capture loop variable properly
		subPrompt := strings.Join(chunkPrompts[i], " ") // TODO- check if it is correct
		go func(subPrompt string) {
			// Tokenize sub-prompt
			tokens, err := k.tokenizer.Encode(subPrompt, modelInfo.Name)
			if err != nil {
				k.logger.Errorf("Tokenization failed for '%s': %v", subPrompt, err)
				return
			}

			// Get prefix hashes
			hashes := k.PrefixCache.GetPrefixHashes(prompt)
			if len(hashes) == 0 {
				return
			}

			// Take only the last hash from the chain
			lastHash := hashes[len(hashes)-1]
			k.PrefixCache.AddTokenPrefix(lastHash, tokens)
		}(subPrompt) // pass as parameter
	}

	k.logger.Infof("Triggered async prefix updates for model=%s (len=%d)", modelInfo.Name, len(prompt))
	return nil
}

// TokensToKVBlockKeys converts token sequences into hashed KV block keys using LMCache format.
func (k *KVCacheIndexer) TokensToKVBlockKeys(tokens Tokens, modelInfo ModelInfo, format int) []string {
	return nil
}

// QueryKVBlockHits queries Redis for pods that contains the block key.
func (k *KVCacheIndexer) QueryKVBlockHits(blockKeys []string) (map[string]string, error) {
	ctx := context.Background()
	results := make(map[string]string)

	if k.redisClient == nil {
		return nil, fmt.Errorf("redis client is not configured")
	}

	cmd := k.redisClient.MGet(ctx, blockKeys...)
	if err := cmd.Err(); err != nil && !errors.Is(err, redis.Nil) {
		return nil, err
	}

	values, err := cmd.Result()
	if err != nil {
		return nil, err
	}

	for i, val := range values {
		if val == nil {
			continue // Redis key not found
		}

		podName, ok := val.(string)
		if !ok {
			k.logger.Warnf("Non-string value in Redis for key %s", blockKeys[i])
			continue
		}

		results[blockKeys[i]] = podName
	}

	return results, nil
}

// FilterRelevantPods filters scored pods against a list of allowed pods.
func (k *KVCacheIndexer) FilterRelevantPods(podList []Pod, availablePods []string) ([]Pod, error) {
	// Create a lookup set from the available pod names
	availableSet := make(map[string]struct{}, len(availablePods))
	for _, podName := range availablePods {
		availableSet[podName] = struct{}{}
	}

	// Filter the pods
	var filtered []Pod
	for _, pod := range podList {
		if _, ok := availableSet[pod.Name]; ok {
			filtered = append(filtered, pod)
		}
	}

	return filtered, nil
}

// RunKVAwarePipeline performs the full KV-aware routing pipeline: prefix lookup, hashing, Redis hits, scoring, and filtering.
func (k *KVCacheIndexer) RunKVAwarePipeline(prompt []string, modelInfo ModelInfo, podList []string) ([]Pod, error) {
	k.logger.Info("Starting KV aware pipeline...")

	// 1. Lookup tokenized prefix
	tokens, needsUpdate, err := k.ExtractPrefixTokens(prompt, modelInfo)
	if err != nil {
		k.logger.Errorf("LookupLongestPrefix failed: %v", err)
		return nil, err
	}

	k.logger.Infof("Tokenized %d tokens (needsUpdate=%v)", len(tokens), needsUpdate)

	// 2. Optionally trigger async update
	if needsUpdate {
		go func() {
			k.logger.Info("Triggering async prefix index update...")
			if err := k.TriggerPrefixIndexUpdate(prompt, modelInfo); err != nil {
				k.logger.Errorf("TriggerPrefixIndexUpdate failed: %v", err)
			}
		}()
	}

	// 3. Chunk tokens into KV block keys
	blockKeys := k.TokensToKVBlockKeys(tokens, modelInfo, 0)

	k.logger.Infof("Generated %d block keys", len(blockKeys))

	// 4. Query with block keys
	hitMap, err := k.QueryKVBlockHits(blockKeys)
	if err != nil {
		k.logger.Errorf("QueryKVBlockHits failed: %v", err)
		return nil, err
	}

	k.logger.Infof("returned hits for %d pods", len(hitMap))

	// 5. Filter pods based on hits
	podScore, err := k.Scorer.Score(blockKeys, hitMap)
	if err != nil {
		k.logger.Errorf("Scorer function failed: %v", err)
		return nil, err
	}
	filteredPods, err := k.FilterRelevantPods(podScore, podList)
	if err != nil {
		k.logger.Errorf("FilterRelevantPods failed: %v", err)
		return nil, err
	}
	k.logger.Infof("%d pods passed relevance filtering", len(filteredPods))

	return filteredPods, nil
}

// RunPrefixAwarePipeline runs a simpler pipeline using only prefix block lookup and filtering (not using Tokens).
func (k *KVCacheIndexer) RunPrefixAwarePipeline(prompt []string, modelInfo ModelInfo, podList []string) ([]Pod, error) {
	k.logger.Info("Starting prefix aware pipeline...")

	podScore, err := k.ExtractPrefixPods(prompt, modelInfo)
	if err != nil {
		k.logger.Errorf("LookupLongestPrefix failed: %v", err)
		return nil, err
	}

	filteredPods, err := k.FilterRelevantPods(podScore, podList)
	if err != nil {
		k.logger.Errorf("FilterRelevantPods failed: %v", err)
		return nil, err
	}
	k.logger.Infof("%d pods passed relevance filtering", len(filteredPods))

	return filteredPods, nil
}

// NewKVCacheIndexer creates a KVCacheIndexer with default scorer and config.
func NewKVCacheIndexer() *KVCacheIndexer {
	return NewKVCacheIndexerWithConfig(nil, nil)
}

// NewKVCacheIndexerWithConfig creates a KVCacheIndexer with the provided scorer and configuration.
func NewKVCacheIndexerWithConfig(scorer KVScorer, cfg *Config) *KVCacheIndexer {
	logger := logrus.WithField("component", "controlplane.control.portmanager")
	logger.Info("Start KVCacheIndexer")

	if scorer == nil {
		scorer = &HighestBlockHitScorer{}
	}

	// Set defaults if config is nil or fields are unset
	if cfg == nil {
		cfg = &Config{
			PrefixHashConfig: prefixhashtable.Config{
				BlockNumber: prefixhashtable.DefaultMaxBlockNumber,
				BlockSize:   prefixhashtable.DefaultBlockSize,
			},
		}
	}

	if cfg.LMChunkSize <= 0 {
		cfg.LMChunkSize = DefaultLMChunkSize
	}

	if cfg.RedisAddr == "" {
		cfg.RedisAddr = "localhost:6379" // Todo-default should change to redis service
	}
	// Set redis client
	redisClient := redis.NewClient(&redis.Options{
		Addr: cfg.RedisAddr,
	})
	tokenizer.NewTokenizer()
	return &KVCacheIndexer{
		Scorer:           scorer,
		logger:           logger,
		lMCacheChunkSize: cfg.LMChunkSize,
		PrefixCache:      prefixhashtable.NewPrefixHashTable(&cfg.PrefixHashConfig),
		redisClient:      redisClient,
		tokenizer:        tokenizer.NewTokenizer(),
	}
}

*/
