PREFIX ?= $(HOME)/.local
BIN := $(PREFIX)/bin/lidless

.PHONY: build test install uninstall clean

build:
	swift build

test:
	swift test

install:
	swift build -c release
	install -d $(PREFIX)/bin
	install -m 0755 .build/release/lidless $(BIN)
	@if [ -f $(HOME)/Library/LaunchAgents/com.lidless.watchdog.plist ]; then $(BIN) setup --agent-only; \
	else echo "installed $(BIN) — run 'lidless setup' once to enable keep-awake"; fi

uninstall:
	rm -f $(BIN)

clean:
	swift package clean
