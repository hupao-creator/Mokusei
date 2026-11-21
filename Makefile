GO ?= ./scripts/go.sh
DEV = $(GO) run ./cmd/chief-dev
ARGS ?=
PBT_ARGS ?=

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
	$(GO) run ./cmd/chief-check architecture
	@chief_goroot="$$($(GO) env GOROOT)" && chief_unformatted="$$("$$chief_goroot/bin/gofmt" -l cmd internal tools)" && { test -z "$$chief_unformatted" || { echo "Run gofmt on: $$chief_unformatted"; exit 1; }; }
	$(GO) vet ./...
typecheck:
	$(GO) build ./...
	xcrun swift build --package-path app/macos
check: lint typecheck
	$(MAKE) pbt

.PHONY: pbt pbt-go pbt-native pbt-native-state pbt-system
.NOTPARALLEL: pbt
pbt: pbt-go pbt-native
pbt-go:
	python3 tools/verification/pbt/run.py --suite go --go "$(GO)" $(PBT_ARGS)
pbt-native:
	python3 tools/verification/pbt/run.py --suite native $(PBT_ARGS)
pbt-native-state:
	python3 tools/verification/pbt/run.py --suite native-state $(PBT_ARGS)
pbt-system:
	python3 tools/verification/pbt/run.py --suite system --go "$(GO)" $(PBT_ARGS)
install-hooks:
	$(GO) run ./cmd/chief-check install-hooks
