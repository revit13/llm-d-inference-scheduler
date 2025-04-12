package tokenization

import (
	"fmt"
	"os"

	"github.com/daulet/tokenizers"
)

// Tokenizer interface defines the methods for tokenization.
type Tokenizer interface {
	// Encode converts a string into token IDs.
	Encode(input, modelName string) ([]uint32, error)
}

// HFTokenizer is a struct that implements the Tokenizer interface using
// bindings to HuggingFace's rust tokenizer.
type HFTokenizer struct {
	cfg tokenizers.TokenizerConfigOption
}

// NewHFTokenizer creates a new instance of HFTokenizer with the provided configuration.
func NewHFTokenizer() Tokenizer {
	cfg := tokenizers.WithAuthToken(os.Getenv("HF_TOKEN")) // Todo- use cache dir
	return &HFTokenizer{
		cfg: cfg,
	}
}

// Encode converts a string into token IDs.
func (t *HFTokenizer) Encode(input, modelName string) ([]uint32, error) {
	tk, err := tokenizers.FromPretrained(modelName, t.cfg)
	if err != nil {
		return nil, err
	}

	defer func(tk *tokenizers.Tokenizer) {
		err := tk.Close()
		if err != nil {
			fmt.Println("Error closing tokenizer:", err)
		}
	}(tk)

	ids, _ := tk.Encode(input, true)
	return ids, nil
}
