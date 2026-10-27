# Artificial Analysis context

[plugin.go](plugin.go) registers `artificial-analysis.evaluation` in the Moku `evaluation` slot at `before-send`. Enablement is `context:artificial-analysis`. The plugin has Context capabilities only; it owns no application records, background agent or native UI.

[source.go](source.go), [parser.go](parser.go), [identity.go](identity.go) and [policy.go](policy.go) own upstream acquisition, cached evaluation facts, native-model attribution and bounded advisory output. Harnesses provide model catalogs; their model/account facts remain authoritative for execution. Evaluation matching does not choose a different model or grant account availability.

Services sharing a cache root share acquisition with reference-counted ownership. Refresh deadlines and failure backoff belong to each catalog identity set: refreshing one catalog cannot postpone another's stale facts or trigger acquisition of a still-fresh catalog. Equal pending identity sets share one generation, while different generations remain serialized; at most 4096 deadline keys are retained. A warm cache returns immediately while its due generation refreshes in the background.

Collection and cached fallback use the declared 21-second timeout. Unavailable measurements remain explicitly unknown. Collection failure follows `abort-send`; cancellation or host closure cancels collection rather than invoking fallback. Catalog callbacks must honor their context; each collection joins all callbacks, including their cancellation cleanup, before returning. Closing a service is idempotent and drains its catalog callbacks and acquisition ownership. The [Context host](../../../hosts/contexthost/README.md) enforces contribution and aggregate bounds, including merged-slot separators.

Source closure stops pending detail dispatch and joins the active workers. It
records one `aa.facts.refresh.cancelled` summary per cancelled generation rather
than per-configuration failures. Catalog cancellation similarly uses
`aa.context.catalog.cancelled`; an individual catalog deadline while its caller
is still live remains a failure. Real acquisition failures retain the existing
cache fallback and refresh backoff.

The composition log bridge preserves only the closed classification vocabulary,
elapsed milliseconds, cache-retention Boolean, known Harness catalog IDs, skip
reasons and bounded generation counts through [diagnostics.go](diagnostics.go).
Refresh duration starts when a queued generation begins; detail and catalog
durations cover their own acquisition. Upstream errors, response bodies, model
names, URLs and filesystem paths are excluded from service diagnostics.

Verification: `./scripts/go.sh run -race ./tools/verification/artificialanalysis` covers independent catalog expiry, failure backoff, invalidation, interleaved acquisition, cancellation of a 100-detail generation, real-failure cache retention and diagnostic redaction; `./scripts/go.sh run -race ./tools/verification/artificialanalysis/lifecycle` covers registration, shared leases, callback cancellation cleanup and classification, joined closure and context bounds.
