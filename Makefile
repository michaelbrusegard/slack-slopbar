.PHONY: build test app install clean

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh release

install:
	./scripts/install-app.sh

clean:
	swift package clean
	rm -rf build

