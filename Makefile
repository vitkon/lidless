PREFIX ?= $(HOME)/.local
BIN := $(PREFIX)/bin/lidsomnia

.PHONY: build test install uninstall clean

build:
	swift build

test:
	swift test

install:
	swift build -c release
	install -d $(PREFIX)/bin
	install -m 0755 .build/release/lidsomnia $(BIN)
	@if [ -f $(HOME)/Library/LaunchAgents/com.lidsomnia.watchdog.plist ]; then $(BIN) setup --agent-only; \
	else echo "installed $(BIN) — run 'lidsomnia setup' once to enable keep-awake"; fi

uninstall:
	rm -f $(BIN)

clean:
	swift package clean
