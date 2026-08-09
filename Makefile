.PHONY: all run install test test-ci clean web web-test infra-test

all:
	$(MAKE) -C apps/macos all

run:
	$(MAKE) -C apps/macos run

install:
	$(MAKE) -C apps/macos install

test:
	$(MAKE) -C apps/macos test

test-ci:
	$(MAKE) -C apps/macos test-ci

clean:
	$(MAKE) -C apps/macos clean

web:
	npm run dev:web

web-test:
	npm run test:web

infra-test:
	npm run test:infra
