# ByLabel Filter Plugins

> Note: This file outlines the available Filter plugins. See the [Architecture Overview](../../../../../../../docs/architecture.md) for details on how filters fit into the scheduling pipeline.

## Contents

- [Available Filters](#available-filters)
  - [ByLabel](#bylabel)
  - [ByLabelSelector](#bylabelselector)
  - [Role-Based Filters](#role-based-filters)
    - [EncodeRole Filter](#encoderole-filter)
    - [PrefillRole Filter](#prefillrole-filter)
    - [DecodeRole Filter](#decoderole-filter)

## Available Filters

### ByLabel

**Type:** `by-label` | **Implementation:** [filter.go](filter.go)

Filters out pods that do not have a specific label with one of the allowed values. Pods missing the label are either filtered out or retained based on the `allowsNoLabel` setting.

**Parameters:**
- `label` (string, required): The name of the Kubernetes label to inspect on each pod.
- `validValues` (list of strings, required unless `allowsNoLabel=true`): A list of acceptable label values. A pod is kept if its label value matches any entry in this list.
- `allowsNoLabel` (boolean, optional, default: `false`): If `true`, pods that **do not have the specified label at all** will be **included** in the candidate set. If `false` (default), such pods are filtered out.

**Configuration Example:**
```yaml
plugins:
  - type: by-label
    parameters:
      label: "gpu.type"
      validValues: ["a100"]
      allowsNoLabel: false
```

In this example:
- Only pods labeled with the specific GPU type (`gpu.type=a100`) are selected.
- Pods missing the `gpu.type` label are not considered for  scheduling.

### ByLabelSelector

**Type:** `by-label-selector` | **Implementation:** [selector.go](selector.go)


Filters out pods using a standard Kubernetes label selector.

> Note: Only the matching labels feature of Kubernetes label selectors is supported.

**Parameters:** A standard Kubernetes label selector.
- `matchLabels`: map of `{key,value}` pairs. If more than one pair are in the map, all of the keys are checked and the results are combined with AND logic.

**Configuration Example:**
```yaml
plugins:
  - type: by-label-selector
    parameters:
      matchLabels:
        inference-role: decode
        hardware-type: H100
```

In this example:
- Only pods that have **both** labels `inference-role=decode` **and** `hardware-type=H100` will be selected.
- Pods missing either label, or having a different value (e.g., `inference-role=prefill`), are **filtered out**.
- The matching logic follows standard Kubernetes label selector semantics: all key-value pairs in `matchLabels` must match (**AND** logic).

### Role-Based Filters

**Implementation:** [roles.go](roles.go)

Pre-configured filters for disaggregated inference architectures based on the `llm-d.ai/role` label.

**Example Target Pod:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  labels:
    llm-d.ai/role: "decode"
spec:
  # ... pod specification
```

#### Inference Roles

| Role | Description |
|------|-------------|
| `encode` | Encode stage only |
| `prefill` | Prefill stage only |
| `decode` | Decode stage only |
| `encode-prefill` | Encode + Prefill |
| `prefill-decode` | Prefill + Decode |
| `encode-prefill-decode` | All stages (monolithic) |

#### EncodeRole Filter

**Type:** `encode-filter`

Filters out pods that are not marked as encode. The filter looks for the label `llm-d.ai/role`, with a value of `encode`, `encode-prefill` or `encode-prefill-decode`.

**Configuration Example:**
```yaml
plugins:
  - type: encode-filter
```

#### PrefillRole Filter

**Type:** `prefill-filter`

Filters out pods that are not marked as prefill. The filter looks for the label `llm-d.ai/role`, with a value of `prefill`, `encode-prefill`, `prefill-decode` or `encode-prefill-decode`.

**Configuration Example:**
```yaml
plugins:
  - type: prefill-filter
```

#### DecodeRole Filter

**Type:** `decode-filter`

Filters out pods that are not authorized for the decode stage. It looks for the `llm-d.ai/role` label with a value of `decode`, `prefill-decode`, or `encode-prefill-decode`. Note: Pods that completely lack the llm-d.ai/role label are not filtered out.

**Configuration Example:**
```yaml
plugins:
  - type: decode-filter
```

## Related Documentation

- [Creating a Custom Filter](../../../../../../../docs/create_new_filter.md)
- [Architecture Overview](../../../../../../../docs/architecture.md)
