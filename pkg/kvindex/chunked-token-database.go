package kvindex

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
)

// TokenDatabase defines the interface for token processing.
type TokenDatabase interface {
	ProcessTokens(tokens []uint32) ([]ProcessedChunk, error)
}

// ProcessedChunk represents one tuple result: the start and end indices and the CacheEngineKey.
type ProcessedChunk struct {
	Start int
	End   int
	Key   CacheEngineKey
}

// CacheEngineKey is equivalent to the LMCacheEngineKey in the Python code.
type CacheEngineKey struct {
	Fmt       string
	ModelName string
	WorldSize int
	WorkerID  int
	ChunkHash string
}

// String returns a string representation of the CacheEngineKey.
func (c CacheEngineKey) String() string {
	/*
	   def to_string(self):
	       return f"{self.fmt}@{self.model_name}@{self.world_size}"\
	           f"@{self.worker_id}@{self.chunk_hash}"
	*/

	return fmt.Sprintf("%s@%s@%d@%d@%s", c.Fmt, c.ModelName, c.WorldSize, c.WorkerID, c.ChunkHash)
}

// LMCacheEngineConfig holds the configuration for the token database.
type LMCacheEngineConfig struct {
	ChunkSize int
}

// LMCacheEngineMetadata holds metadata used to populate the cache key.
type LMCacheEngineMetadata struct {
	Fmt       string
	ModelName string
	WorldSize int
	WorkerID  int
}

// ChunkedTokenDatabase is a concrete implementation of TokenDatabase.
// It mimics the ChunkedTokenDatabase in the Python code.
type ChunkedTokenDatabase struct {
	chunkSize int
	metadata  LMCacheEngineMetadata
}

// NewChunkedTokenDatabase creates a new instance with the given config and metadata.
func NewChunkedTokenDatabase(config LMCacheEngineConfig, metadata LMCacheEngineMetadata) TokenDatabase {
	return &ChunkedTokenDatabase{
		chunkSize: config.ChunkSize,
		metadata:  metadata,
	}
}

// getInitHash returns the initial hash.
func (db *ChunkedTokenDatabase) getInitHash() string {
	return ""
}

// hash computes the SHA-256 hash of the concatenation of the prefixHash and the binary
// representation of the tokens slice. It returns the hex-encoded string.
func (db *ChunkedTokenDatabase) hash(tokens []uint32, prefixHash string) string {
	buf := new(bytes.Buffer)
	// write the prefixHash bytes (ASCII encoding)
	buf.WriteString(prefixHash)
	// write each token to the buffer as binary data (using 64-bit big-endian format)
	for _, token := range tokens {
		// convert token to int64 for binary consistency
		// LittleEndian is important to match the Python code
		if err := binary.Write(buf, binary.LittleEndian, int64(token)); err != nil {
			// In production code, you might handle this error appropriately.
			panic(err)
		}
	}
	sum := sha256.Sum256(buf.Bytes())
	return hex.EncodeToString(sum[:])
}

// chunkTokens splits the input slice of tokens into chunks of size chunkSize.
func (db *ChunkedTokenDatabase) chunkTokens(tokens []uint32) [][]uint32 {
	var chunks [][]uint32
	for i := 0; i < len(tokens); i += db.chunkSize {
		end := i + db.chunkSize
		if end > len(tokens) {
			end = len(tokens)
		}
		chunks = append(chunks, tokens[i:end])
	}
	return chunks
}

// prefixHashes computes the rolling (prefix) hash for each chunk and
// returns a slice of hash strings. It starts from the initial hash
// and then for each token chunk it computes the new hash.
func (db *ChunkedTokenDatabase) prefixHashes(tokenChunks [][]uint32) []string {
	prefixHash := db.getInitHash()
	hashes := make([]string, len(tokenChunks))
	for i, chunk := range tokenChunks {
		prefixHash = db.hash(chunk, prefixHash)
		hashes[i] = prefixHash
	}
	return hashes
}

// makeKeyByHash creates a CacheEngineKey given the chunk hash.
func (db *ChunkedTokenDatabase) makeKeyByHash(chunkHash string) CacheEngineKey {
	return CacheEngineKey{
		Fmt:       db.metadata.Fmt,
		ModelName: db.metadata.ModelName,
		WorldSize: db.metadata.WorldSize,
		WorkerID:  db.metadata.WorkerID,
		ChunkHash: chunkHash,
	}
}

// ProcessTokens processes a slice of tokens by chunking them,
// updating a rolling hash for every chunk, and building a CacheEngineKey for each.
// It returns a slice of ProcessedChunk with start/end indices and key.
func (db *ChunkedTokenDatabase) ProcessTokens(tokens []uint32) ([]ProcessedChunk, error) {
	totalLen := len(tokens)
	tokenChunks := db.chunkTokens(tokens)
	prefixHashes := db.prefixHashes(tokenChunks)
	var results []ProcessedChunk

	for i, hashVal := range prefixHashes {
		startIdx := i * db.chunkSize
		endIdx := startIdx + db.chunkSize
		if endIdx > totalLen {
			endIdx = totalLen
		}
		results = append(results, ProcessedChunk{
			Start: startIdx,
			End:   endIdx,
			Key:   db.makeKeyByHash(hashVal),
		})
	}
	return results, nil
}
