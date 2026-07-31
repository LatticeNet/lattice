.PHONY: test build check-clean test-check-clean run-server run-agent check-dashboard

export GOCACHE := $(CURDIR)/.cache/go-build
export GOWORK := $(CURDIR)/go.work

WORKSPACE_REPOS := . ../lattice-sdk ../lattice-server ../lattice-node-agent ../lattice-plugin-template

test:
	mkdir -p $(GOCACHE)
	cd ../lattice-sdk && go test ./...
	cd ../lattice-server && go test ./...
	cd ../lattice-node-agent && go test ./...

build:
	mkdir -p bin
	mkdir -p $(GOCACHE)
	cd ../lattice-server && go build -o ../lattice/bin/lattice-server ./cmd/lattice-server
	cd ../lattice-node-agent && go build -o ../lattice/bin/lattice-agent ./cmd/lattice-agent
	cd ../lattice-plugin-template/system-go && go build ./...

check-clean:
	@dirty=0; \
	for repo in $(WORKSPACE_REPOS); do \
		if ! status="$$(git -C "$$repo" status --porcelain --untracked-files=all)"; then \
			printf 'workspace checkout cannot be inspected: %s\n' "$$repo" >&2; \
			dirty=1; \
			continue; \
		fi; \
		if [ -n "$$status" ]; then \
			printf 'workspace checkout is dirty: %s\n%s\n' "$$repo" "$$status" >&2; \
			dirty=1; \
		fi; \
	done; \
	test "$$dirty" -eq 0

test-check-clean:
	@sh scripts/test-check-clean.sh

run-server:
	cd ../lattice-server && LATTICE_WEB_ROOT=../lattice-dashboard go run ./cmd/lattice-server

run-agent:
	cd ../lattice-node-agent && go run ./cmd/lattice-agent

check-dashboard:
	cd ../lattice-dashboard && pnpm build
