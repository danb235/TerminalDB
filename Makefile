.PHONY: all run install test test-ci clean

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
