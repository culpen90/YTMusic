.PHONY: build test app run clean

build:
	swift build

test:
	swift test

app:
	./Scripts/build-app.sh

run: app
	open ./dist/YTMusic.app

clean:
	swift package clean
	@if [ -d "$(CURDIR)/dist/YTMusic.app" ]; then /bin/rm -rf "$(CURDIR)/dist/YTMusic.app"; fi
	@if [ -f "$(CURDIR)/dist/YTMusic.zip" ]; then /bin/rm -f "$(CURDIR)/dist/YTMusic.zip"; fi
