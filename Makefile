.PHONY: test build run-server run-agent check-dashboard

export GOCACHE := $(CURDIR)/.cache/go-build
export GOWORK := $(CURDIR)/go.work

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

run-server:
	cd ../lattice-server && LATTICE_WEB_ROOT=../lattice-dashboard go run ./cmd/lattice-server

run-agent:
	cd ../lattice-node-agent && go run ./cmd/lattice-agent

check-dashboard:
	cd ../lattice-dashboard && pnpm build
