.PHONY: build test app dmg install clean

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh release

dmg:
	./scripts/package-dmg.sh

install:
	./scripts/install-app.sh

clean:
	swift package clean
	rm -rf build dist
