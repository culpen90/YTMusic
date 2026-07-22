.PHONY: build test app run clean

build:
	swift build

test:
	swift test

app:
	./Scripts/build-app.sh

run: app
	open ./dist/Liltfinch.app

clean:
	swift package clean
	@if [ -d "$(CURDIR)/dist/Liltfinch.app" ]; then /bin/rm -rf "$(CURDIR)/dist/Liltfinch.app"; fi
	@if [ -f "$(CURDIR)/dist/Liltfinch.zip" ]; then /bin/rm -f "$(CURDIR)/dist/Liltfinch.zip"; fi
