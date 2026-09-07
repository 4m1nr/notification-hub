# notification-hub

GO      ?= go
BIN     := bin
CMDS    := rss-relay syslog-ntfy mail-watcher mattermost-watcher
LDFLAGS := -s -w

.PHONY: all build vet test fmt check clean install-vps install-office

all: check build

## build: compile every service into ./bin (static, no runtime deps)
build:
	@mkdir -p $(BIN)
	@for cmd in $(CMDS); do \
		echo "building $$cmd"; \
		CGO_ENABLED=0 $(GO) build -trimpath -ldflags="$(LDFLAGS)" -o $(BIN)/$$cmd ./cmd/$$cmd || exit 1; \
	done

vet:
	$(GO) vet ./...

test:
	$(GO) test ./...

fmt:
	gofmt -w $(shell find . -name '*.go' -not -path './vendor/*')

## check: everything CI would run, including shell and unit-file validation
check: vet test
	@echo "checking shell scripts"
	@find . -name '*.sh' -not -path './.git/*' -exec bash -n {} \; -print
	@command -v shellcheck >/dev/null && \
		find . -name '*.sh' -not -path './.git/*' -exec shellcheck -S warning {} + || \
		echo "shellcheck not installed, skipping"
	@command -v systemd-analyze >/dev/null && \
		systemd-analyze verify vps/systemd/*.service office-pc/systemd/*.service 2>&1 | grep -v '^$$' || \
		echo "systemd-analyze not available, skipping"
	@./scripts/check-configs.sh

clean:
	rm -rf $(BIN)

## install-vps: run the full VPS bootstrap (must be root)
install-vps:
	./bootstrap.sh

## install-office: install the office PC watchers (must be root)
install-office:
	./office-pc/install.sh
