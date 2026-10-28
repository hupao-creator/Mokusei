# Artificial Analysis integration replays

Run from the repository root:

```sh
./scripts/go.sh run -race ./tools/verification/artificialanalysis
./scripts/go.sh run -race ./tools/verification/artificialanalysis/lifecycle
```

The acquisition replay exercises the production Source and Moku formatters with
public-page-shaped protocol fixtures and a temporary persisted cache. It covers
all nine Intelligence Index v5.0 evaluations (ten component metrics), raw units,
null/zero semantics, obsolete-field exclusion and detailed/compact context.
Missing, old, future, malformed and conflicting index/detail versions cannot
replace verified facts. Old cache schemas and absent/mismatched versions are
discarded; offline fallback and 304 responses cannot resurrect those scores or
carry an unrefreshed legacy catalog into the v5 cache.

Existing replay cases cover identity/provenance matching, ETags, immediate warm
cache returns, independent catalog refresh, failure backoff, cancellation,
joined disposal, diagnostic redaction and bounded atomic compact rows. The
lifecycle replay exercises the Context host/runtime boundary and shared leases.

To also check current public roster/detail acquisition through the production
parser, provide an existing AA release slug:

```sh
./scripts/go.sh run -race ./tools/verification/artificialanalysis -live-release step-5-preview
```

This opt-in check needs network access but no API key. It uses a temporary cache,
requires verified v5.0 measurements and checks the rendered context version.
It intentionally fails if the release is removed or AA changes its supported
methodology or page contract. Offline replays remain deterministic.
