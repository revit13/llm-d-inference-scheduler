# Models Data Layer Plugins

## Contents

- [Available Data Layer Plugins](#available-data-layer-plugins)
  - [ModelsDataSource](#modelsdatasource)
  - [ModelServerExtractor](#modelserverextractor)

## Available Data Layer Plugins

These two plugins work together and require a small amount of wiring in the `EndpointPickerConfig`:

- Both are declared under `plugins:` (like any other plugin).
- They are linked in a separate top-level `data: sources:` section, which tells the framework which extractor(s) to invoke when a given data source finishes fetching. This section is distinct from `schedulingProfiles:`.
- The string `"dataLayer"` must appear in the top-level `featureGates:` list. This is an experimental feature gate defined in [GIE (`ExperimentalDatalayerFeatureGate`)](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/pkg/epp/datalayer/factory.go) — without it the EPP ignores the `data:` section entirely; with it the EPP requires `data: sources:` to be present (missing it causes a startup error).

On each scheduling cycle: the data source polls every pod in the `InferencePool` individually (`GET scheme://pod-ip:metricsPort/path`), the extractor converts each response into a `ModelInfoCollection` stored on that pod's endpoint, and filters/scorers access it via `endpoint.GetAttributes().Get("/v1/models")`.

### ModelsDataSource

**Type:** `models-data-source`

Fetches model information from inference servers using HTTP/HTTPS requests to the `/v1/models` endpoint (or a configured path).

**Parameters:**
- `scheme` (string, optional, default: `"http"`): Protocol scheme: `"http"` or `"https"`.
- `path` (string, optional, default: `"/v1/models"`): URL path for the models API endpoint.
- `insecureSkipVerify` (bool, optional, default: `true`): Skip TLS certificate verification.

**Configuration Example:**
```yaml
- type: models-data-source
  name: my-models-source
  parameters:
    scheme: "http"
    path: "/v1/models"
    insecureSkipVerify: true
```

#### Expected API Response Format

The data source expects responses in the OpenAI-compatible format:

```json
{
  "object": "list",
  "data": [
    { "id": "llama-3-8b", "parent": "llama-3" },
    { "id": "mistral-7b", "parent": "mistral" }
  ]
}
```

### ModelServerExtractor

**Type:** `model-server-protocol-models`

Extracts model information from the data source response and stores it as a `ModelInfoCollection` at attribute key `/v1/models` on each endpoint.

No configuration parameters.

**Configuration Example:**
```yaml
- type: model-server-protocol-models
  name: my-models-extractor
```

#### Accessing Extracted Data

```go
attr, ok := endpoint.GetAttributes().Get("/v1/models")
if !ok || attr == nil {
    return fmt.Errorf("no models found")
}
models, ok := attr.(models.ModelInfoCollection)
```

#### Complete Configuration Example

```yaml
apiVersion: inference.networking.x-k8s.io/v1alpha1
kind: EndpointPickerConfig
featureGates:
- dataLayer
plugins:
- type: models-data-source
  name: vllm-models-source
  parameters:
    scheme: "https"
    path: "/v1/models"
    insecureSkipVerify: false
- type: model-server-protocol-models
  name: vllm-models-extractor
# ... other plugins (filters, scorers, profile handler, picker) ...
data:
  sources:
  - pluginRef: vllm-models-source
    extractors:
    - pluginRef: vllm-models-extractor
```

## Related Documentation

- [Architecture Overview](../../../../../../../docs/architecture.md)
- [Scorer Plugins](../../../scheduling/scorer/README.md)
- [Filter Plugins](../../../scheduling/filter/bylabel/README.md)
