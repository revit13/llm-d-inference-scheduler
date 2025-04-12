package tokenization

// TokenIndexer is a small interface that defines the methods needed for updating
// our prefix-to-tokens index.
type TokenIndexer interface {
	// Update updates the token index for the given prefix.
	Update(prefix string, tokenCount int)
	// (Optionally) a method to retrieve data from the index.
	Get(prefix string) (int, bool)
}
