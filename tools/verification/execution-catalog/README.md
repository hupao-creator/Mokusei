# Execution catalog and preview projection

`execution_projection_test.go` runs the production Claude, Codex, Pi and
OpenCode state adapters. It fixes the current card/reply plus 96 unrelated
completed executions and asserts the entire overview projection stays
byte-identical, under `model.MaxThreadOverviewBytes`, and free of unrelated
message, author, usage and inherited identities. The same fixtures page the
complete chronological directory, check out-of-range pages, resolve earlier
execution previews by exact ID and cover Codex fork history. A runtime case
stores a fork-only Codex session and verifies inherited directory/preview titles
through the real Runtime envelope. The report relation replay confirms a cited
fork execution keeps its own timing while current Thread facts remain separate.

```sh
./scripts/go.sh test -race ./tools/verification/execution-catalog -v
```

Runtime catalog/title stripping, the full-content envelope, directory title
attachment, the `thread:execution-previews` envelope and real record/catalog/
mutation byte counts are covered by
[`internal/core/runtime/execution_catalog_test.go`](../../../internal/core/runtime/execution_catalog_test.go).
