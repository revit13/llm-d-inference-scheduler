# Tokenizer Plugin

## Contents

- [Tokenizer](#tokenizer)
  - [Scorer Mode (default)](#scorer-mode-default)
  - [PrepareData Mode](#preparedata-mode-gaie_tokenized_prompt-tag)


## Tokenizer

**Type:** `tokenizer` | **Interfaces:** [`scheduling.Scorer`](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/pkg/epp/framework/interface/scheduling/plugins.go) (default) · [`requestcontrol.PrepareDataPlugin`](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/pkg/epp/framework/interface/requestcontrol/plugins.go) (build-tag)

Converts incoming LLM prompts (both standard text completions and multi-modal chat messages) into token IDs for downstream filters and scorers. Communicates via Unix Domain Socket (UDS) with a tokenizer service from [`github.com/llm-d/llm-d-kv-cache/pkg/tokenization`](https://github.com/llm-d/llm-d-kv-cache), which runs as a separate sidecar container alongside the EPP pod. An embedded (in-process) alternative is also available in the same package. Fail-open: tokenization errors are logged and scheduling continues without token data.


**Parameters:**
- `modelName` (string, required): Model name whose tokenizer to load.
- `udsTokenizerConfig.socketFile` (string, optional, default: `"/tmp/tokenizer/tokenizer-uds.socket"`): Path to the Unix domain socket.
- `udsTokenizerConfig.timeout` (string, optional, default: `"5s"`): Timeout for tokenizer requests (Go duration string).
- `udsTokenizerConfig.maxRetries` (int, optional, default: `3`): Maximum retry attempts.

### Scorer Mode (default)

Registered under `scorers:` in config. The plugin uses the `Score` call as a hook to tokenize the request and write the result into `CycleState` — a per-request scratchpad shared across all scorers in the same scheduling cycle. It always returns zero scores for every pod so it has no effect on ranking; its sole purpose is to make the token IDs available to downstream scorers (e.g. [`precise-prefix-cache-scorer`](../../../scheduling/scorer/README.md#precise-prefix-cache-scorer), [`context-length-aware`](../../../scheduling/scorer/README.md#context-length-aware-scorer)) without those scorers needing to re-tokenize.

Read by downstream plugins:

```go
state, err := scheduling.ReadCycleStateKey[*tokenizer.TokenizedPromptState](
    cycleState, tokenizer.TokenizedPromptStateKey,
)
```

> **Note:** Multi-modal features (`MMFeatures`) are only populated in scorer mode. PrepareData mode stores token IDs only.

**Configuration Example:**
```yaml
- type: tokenizer
  name: tokenizer
  weight: 0
  parameters:
    modelName: "llama-3-8b"
    udsTokenizerConfig:
      socketFile: "/tmp/tokenizer/tokenizer-uds.socket"
      timeout: "5s"
      maxRetries: 3
```

**Configuration Example — with cache-aware routing:**
```yaml
plugins:
  - type: tokenizer
    parameters:
      modelName: "llama-3-8b"
  - type: precise-prefix-cache-scorer
    name: cache-scorer
schedulingProfiles:
  - name: default
    plugins:
      - pluginRef: tokenizer
        weight: 0
      - pluginRef: cache-scorer
        weight: 10
```

**Configuration Example — with context-length routing:**
```yaml
plugins:
  - type: tokenizer
    parameters:
      modelName: "llama-3-8b"
  - type: context-length-aware
    name: context-router
    parameters:
      label: "llm-d.ai/context-length-range"
schedulingProfiles:
  - name: default
    plugins:
      - pluginRef: tokenizer
        weight: 0
      - pluginRef: context-router
        weight: 8
```

### PrepareData Mode (`gaie_tokenized_prompt` tag)

```bash
go build -tags gaie_tokenized_prompt
```

Implements [`requestcontrol.PrepareDataPlugin`](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/pkg/epp/framework/interface/requestcontrol/plugins.go); registered under `prepareData:` in config. Stores token IDs directly on `request.TokenizedPrompt` and runs in the PrepareData phase, before filters and scorers. Use this mode when the GAIE framework version exposes `LLMRequest.TokenizedPrompt`.

**Configuration Example:**
```yaml
plugins:
  - type: precise-prefix-cache-scorer
    name: cache-scorer
prepareData:
  - type: tokenizer
    name: tokenizer
    parameters:
      modelName: "llama-3-8b"
      udsTokenizerConfig:
        socketFile: "/var/run/tokenizer/llama.socket"
        timeout: "10s"
schedulingProfiles:
  - name: default
    plugins:
      - pluginRef: cache-scorer
        weight: 10
```

## Related Documentation

- [Architecture Overview](../../../../../../../docs/architecture.md)
- [Scorer README](../../../scheduling/scorer/README.md)
