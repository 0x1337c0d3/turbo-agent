SWIFT ?= swift
INSTALL ?= install
CONFIGURATION ?= release
RUN_ARGS ?=
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
DESTDIR ?=

.PHONY: build build-app test run install

build:
	$(SWIFT) build -c $(CONFIGURATION)

build-app: build
	Scripts/package-agent.sh "$(CONFIGURATION)"

test:
	Scripts/test.sh
	python3 Scripts/test-agent-editor.py
	python3 Scripts/test-agent-transcript.py
	ruby Scripts/check_tracked_symlinks.rb
	ruby Scripts/check_markdown_links.rb

run: build
	.build/$(CONFIGURATION)/TurboAgent $(RUN_ARGS)

install: build
	$(INSTALL) -d "$(DESTDIR)$(BINDIR)"
	$(INSTALL) -m 0755 ".build/$(CONFIGURATION)/TurboAgent" \
		"$(DESTDIR)$(BINDIR)/TurboAgent"
