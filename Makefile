GO ?= ./scripts/go.sh
DEV = $(GO) run ./cmd/mokusei-dev
ARGS ?=

.PHONY: runtime build dev fast watch-main pack dist smoke install open lint typecheck pbt check check-directorytag check-swift install-hooks
runtime:
	$(DEV) runtime
build:
	$(DEV) build $(ARGS)
dev:
	$(DEV) dev $(ARGS)
fast:
	$(DEV) fast $(ARGS)
watch-main:
	$(DEV) watch-main $(ARGS)
pack:
	$(DEV) bundle $(ARGS)
dist:
	$(DEV) bundle --zip $(ARGS)
smoke:
	$(DEV) smoke $(ARGS)
install:
	$(DEV) install $(ARGS)
open:
	$(DEV) open $(ARGS)
lint:
	$(GO) run ./cmd/mokusei-check architecture
	@mokusei_goroot="$$($(GO) env GOROOT)" && mokusei_unformatted="$$("$$mokusei_goroot/bin/gofmt" -l cmd internal tools)" && { test -z "$$mokusei_unformatted" || { echo "Run gofmt on: $$mokusei_unformatted"; exit 1; }; }
	$(GO) vet ./...
typecheck:
	$(GO) build ./...
	xcrun swift build --package-path app/macos --build-tests
pbt:
	$(GO) test -race ./tools/verification/runtime-concurrency ./tools/verification/codex -run Properties -count=1 $(ARGS)
check-directorytag:
	$(GO) test ./internal/services/directorytag ./internal/plugins/applications/report
check-swift:
	xcrun swift test --package-path app/macos
check: lint typecheck pbt check-modules check-directorytag check-swift
install-hooks:
	$(GO) run ./cmd/mokusei-check install-hooks

.PHONY: check-modules
check-modules:
	$(GO) test -race ./internal/plugins/... ./internal/hosts/... ./internal/core/runtime ./internal/services/moku ./internal/platform/discovery ./internal/platform/environment

.PHONY: check-system
check-system:
	@test -n "$(MOKUSEI_SYSTEM_CODEX)" || { echo 'Set MOKUSEI_SYSTEM_CODEX to the native Codex executable'; exit 1; }
	$(GO) test -race ./tools/verification/moku-system -rapid.checks=8 -count=1 -timeout=10m $(ARGS)

.PHONY: check-stability
check-stability:
	@test -n "$(MOKUSEI_SYSTEM_CODEX)" || { echo 'Set MOKUSEI_SYSTEM_CODEX to the native Codex executable'; exit 1; }
	@test -n "$(STABILITY_OUTPUT)" || { echo 'Set STABILITY_OUTPUT to a new evidence directory'; exit 1; }
	@mkdir -p .build/verification
	$(GO) build -trimpath -o .build/verification/stability-runtime ./cmd/mokusei-runtime
	$(GO) run -race ./tools/verification/moku-system -codex "$(MOKUSEI_SYSTEM_CODEX)" -runtime "$(CURDIR)/.build/verification/stability-runtime" -evidence "$(STABILITY_OUTPUT)" $(ARGS)
