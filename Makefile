GO ?= ./scripts/go.sh
DEV = $(GO) run ./cmd/mokusei-dev
ARGS ?=

.PHONY: runtime build dev fast watch-main pack dist alpha smoke install open lint typecheck check install-hooks
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
alpha:
	$(DEV) alpha $(ARGS)
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
	xcrun swift build --package-path app/macos
check: lint typecheck
install-hooks:
	$(GO) run ./cmd/mokusei-check install-hooks
