.PHONY: all build clean test

all: build

build:
	@mkdir -p bin
	cd backend && CGO_ENABLED=0 go build -ldflags="-s -w" -o ../bin/omakube .

clean:
	rm -f bin/omakube

test:
	cd backend && go test ./...
